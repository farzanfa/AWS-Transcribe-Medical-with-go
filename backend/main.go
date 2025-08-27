package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/transcribestreaming"
	"github.com/aws/aws-sdk-go-v2/service/transcribestreaming/types"
	"github.com/gorilla/websocket"
	"github.com/joho/godotenv"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		// Allow all origins in development
		return true
	},
}

type Config struct {
	AWSAccessKeyID       string
	AWSSecretAccessKey   string
	TranscribeRegion     string
	S3Region             string
	S3Bucket             string
	S3Prefix             string
	TranscribeLanguage   string
	TranscribeSpecialty  string
	TranscribeType       string
	SampleRateHz         int32
}

type WSMessage struct {
	Type   string `json:"type"`
	Text   string `json:"text,omitempty"`
	Key    string `json:"key,omitempty"`
	Action string `json:"action,omitempty"`
}

type TranscriptionSession struct {
	conn            *websocket.Conn
	transcribeClient *transcribestreaming.Client
	s3Client        *s3.Client
	config          Config
	transcripts     []string
	lastTranscript  string // Track the last transcript to detect duplicates
	mu              sync.Mutex
	ctx             context.Context
	cancel          context.CancelFunc
}

func loadConfig() (*Config, error) {
	// Load .env file if it exists
	godotenv.Load()

	sampleRate, err := strconv.ParseInt(os.Getenv("SAMPLE_RATE_HZ"), 10, 32)
	if err != nil {
		sampleRate = 16000
	}

	return &Config{
		AWSAccessKeyID:       os.Getenv("AWS_ACCESS_KEY_ID"),
		AWSSecretAccessKey:   os.Getenv("AWS_SECRET_ACCESS_KEY"),
		TranscribeRegion:     getEnvOrDefault("TRANSCRIBE_REGION", "us-east-1"),
		S3Region:             getEnvOrDefault("S3_BUCKET_REGION", "us-east-1"),
		S3Bucket:             os.Getenv("S3_BUCKET"),
		S3Prefix:             getEnvOrDefault("S3_PREFIX", "medical-transcriptions"),
		TranscribeLanguage:   getEnvOrDefault("TRANSCRIBE_LANGUAGE_CODE", "en-US"),
		TranscribeSpecialty:  getEnvOrDefault("TRANSCRIBE_SPECIALTY", "PRIMARYCARE"),
		TranscribeType:       getEnvOrDefault("TRANSCRIBE_TYPE", "DICTATION"),
		SampleRateHz:         int32(sampleRate),
	}, nil
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal("Failed to load config:", err)
	}

	http.HandleFunc("/health", healthHandler)
	http.HandleFunc("/ws/medical/direct", func(w http.ResponseWriter, r *http.Request) {
		wsHandler(w, r, cfg)
	})

	port := getEnvOrDefault("PORT", "8000")
	log.Printf("Server starting on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal("Server failed:", err)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

func wsHandler(w http.ResponseWriter, r *http.Request, cfg *Config) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}
	defer conn.Close()

	// Get query parameters for specialty and type
	specialty := r.URL.Query().Get("specialty")
	if specialty == "" {
		specialty = cfg.TranscribeSpecialty
	}
	
	transcribeType := r.URL.Query().Get("type")
	if transcribeType == "" {
		transcribeType = cfg.TranscribeType
	}

	// Create AWS clients
	awsCfg, err := config.LoadDefaultConfig(context.Background(),
		config.WithRegion(cfg.TranscribeRegion),
	)
	if err != nil {
		log.Printf("Failed to load AWS config: %v", err)
		return
	}

	transcribeClient := transcribestreaming.NewFromConfig(awsCfg)
	
	// S3 client might be in a different region
	s3Cfg, err := config.LoadDefaultConfig(context.Background(),
		config.WithRegion(cfg.S3Region),
	)
	if err != nil {
		log.Printf("Failed to load S3 config: %v", err)
		return
	}
	s3Client := s3.NewFromConfig(s3Cfg)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Create config copy with overrides
	sessionConfig := *cfg
	sessionConfig.TranscribeSpecialty = specialty
	sessionConfig.TranscribeType = transcribeType

	session := &TranscriptionSession{
		conn:             conn,
		transcribeClient: transcribeClient,
		s3Client:         s3Client,
		config:           sessionConfig,
		ctx:              ctx,
		cancel:           cancel,
		transcripts:      []string{},
		lastTranscript:   "",
	}

	session.handleConnection()
}

func (s *TranscriptionSession) handleConnection() {
	log.Println("WebSocket connection established")

	// Start the transcription stream
	streamInput := &transcribestreaming.StartMedicalStreamTranscriptionInput{
		LanguageCode:         types.LanguageCode(s.config.TranscribeLanguage),
		MediaSampleRateHertz: aws.Int32(s.config.SampleRateHz),
		MediaEncoding:        types.MediaEncodingPcm,
		Specialty:            types.Specialty(s.config.TranscribeSpecialty),
		Type:                 types.Type(s.config.TranscribeType),
		EnableChannelIdentification: true,
		NumberOfChannels:     aws.Int32(2),
	}

	stream, err := s.transcribeClient.StartMedicalStreamTranscription(s.ctx, streamInput)
	if err != nil {
		log.Printf("Failed to start transcription stream: %v", err)
		s.sendError("Failed to start transcription")
		return
	}

	// Create channels for communication
	audioChan := make(chan []byte, 100)
	doneChan := make(chan struct{})

	// Start goroutine to handle transcription events
	go s.handleTranscriptionEvents(stream, doneChan)

	// Start goroutine to send audio to Transcribe
	go s.sendAudioToTranscribe(stream, audioChan, doneChan)

	// Read messages from WebSocket
	for {
		messageType, message, err := s.conn.ReadMessage()
		if err != nil {
			log.Printf("WebSocket read error: %v", err)
			break
		}

		if messageType == websocket.TextMessage {
			// Handle control messages
			var msg WSMessage
			if err := json.Unmarshal(message, &msg); err == nil {
				if msg.Type == "control" && msg.Action == "stop" {
					log.Println("Received stop command")
					break
				}
			}
		} else if messageType == websocket.BinaryMessage {
			// Forward audio data
			select {
			case audioChan <- message:
			case <-s.ctx.Done():
				break
			default:
				log.Println("Audio buffer full, dropping frame")
			}
		}
	}

	// Clean up
	close(audioChan)
	s.cancel()
	<-doneChan

	// Save transcription to S3
	if len(s.transcripts) > 0 {
		s.saveToS3()
	}
}

func (s *TranscriptionSession) handleTranscriptionEvents(stream *transcribestreaming.StartMedicalStreamTranscriptionOutput, done chan struct{}) {
	defer close(done)

	eventStream := stream.GetStream()
	defer eventStream.Close()

		for {
		select {
		case <-s.ctx.Done():
			return
		case event, ok := <-eventStream.Events():
			if !ok {
				return
			}

			switch v := event.(type) {
			case *types.MedicalTranscriptResultStreamMemberTranscriptEvent:
				if v.Value.Transcript != nil {
					s.processTranscriptEvent(*v.Value.Transcript)
				}
			}
		}
	}
}

func (s *TranscriptionSession) processTranscriptEvent(event types.MedicalTranscript) {
	for _, result := range event.Results {
		if len(result.Alternatives) > 0 {
			alternative := result.Alternatives[0]
			text := aws.ToString(alternative.Transcript)
			
			if text == "" {
				continue
			}

			if !result.IsPartial {
				// Final transcript
				log.Printf("Received final transcript: %s", text)
				
				s.mu.Lock()
				// Check if this transcript is different from the last one or contains the last one
				isDuplicate := false
				if s.lastTranscript != "" {
					// Check if the new transcript is identical to the last one
					if text == s.lastTranscript {
						isDuplicate = true
						log.Printf("Detected exact duplicate transcript, skipping")
					} else if strings.Contains(text, s.lastTranscript) {
						// Check if the new transcript contains the entire last transcript
						// This handles cases where AWS extends the previous transcript
						isDuplicate = true
						// Extract only the new part
						newPart := strings.TrimSpace(strings.Replace(text, s.lastTranscript, "", 1))
						if newPart != "" {
							text = newPart
							isDuplicate = false
							log.Printf("Extracted new part from extended transcript: %s", text)
						} else {
							log.Printf("Detected duplicate within extended transcript, skipping")
						}
					} else if len(s.transcripts) > 0 {
						// Check if any recent transcript is contained in the new one
						// This handles cases where AWS might repeat older segments
						for i := len(s.transcripts) - 1; i >= 0 && i >= len(s.transcripts)-3; i-- {
							if strings.Contains(text, s.transcripts[i]) {
								isDuplicate = true
								log.Printf("Detected transcript contains previous segment: %s", s.transcripts[i])
								break
							}
						}
					}
				}
				
				if !isDuplicate {
					s.transcripts = append(s.transcripts, text)
					s.lastTranscript = text
					log.Printf("Added transcript. Total transcripts stored: %d", len(s.transcripts))
				}
				s.mu.Unlock()

				if !isDuplicate {
					msg := WSMessage{
						Type: "final",
						Text: text,
					}
					s.sendMessage(msg)
				}
			} else {
				// Partial transcript
				msg := WSMessage{
					Type: "partial",
					Text: text,
				}
				s.sendMessage(msg)
			}
		}
	}
}

func (s *TranscriptionSession) sendAudioToTranscribe(stream *transcribestreaming.StartMedicalStreamTranscriptionOutput, audioChan <-chan []byte, done <-chan struct{}) {
	eventStream := stream.GetStream()

	for {
		select {
		case audio, ok := <-audioChan:
			if !ok {
				// Channel closed, send completion
				eventStream.Send(s.ctx, &types.AudioStreamMemberAudioEvent{
					Value: types.AudioEvent{
						AudioChunk: []byte{},
					},
				})
				return
			}

			// Send audio chunk
			err := eventStream.Send(s.ctx, &types.AudioStreamMemberAudioEvent{
				Value: types.AudioEvent{
					AudioChunk: audio,
				},
			})
			if err != nil {
				log.Printf("Error sending audio: %v", err)
				return
			}

		case <-done:
			return
		case <-s.ctx.Done():
			return
		}
	}
}

func (s *TranscriptionSession) saveToS3() {
	s.mu.Lock()
	log.Printf("Saving transcription with %d segments", len(s.transcripts))
	for i, transcript := range s.transcripts {
		log.Printf("Transcript segment %d: %s", i, transcript)
	}
	fullText := strings.Join(s.transcripts, " ")
	s.mu.Unlock()

	if fullText == "" {
		log.Println("No transcription to save")
		return
	}
	
	log.Printf("Full transcription to save: %s", fullText)

	// Generate filename with timestamp
	timestamp := time.Now().Format("2006-01-02_15-04-05")
	key := fmt.Sprintf("%s/transcription_%s.txt", s.config.S3Prefix, timestamp)

	// Upload to S3 with a fresh context since the session context may be canceled
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	
	_, err := s.s3Client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(s.config.S3Bucket),
		Key:         aws.String(key),
		Body:        strings.NewReader(fullText),
		ContentType: aws.String("text/plain"),
	})

	if err != nil {
		log.Printf("Failed to upload to S3: %v", err)
		s.sendError("Failed to save transcription")
		return
	}

	log.Printf("Transcription saved to S3: %s", key)
	msg := WSMessage{
		Type: "saved",
		Key:  key,
	}
	s.sendMessage(msg)
}

func (s *TranscriptionSession) sendMessage(msg WSMessage) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := s.conn.WriteJSON(msg); err != nil {
		log.Printf("Error sending message: %v", err)
	}
}

func (s *TranscriptionSession) sendError(errorMsg string) {
	msg := WSMessage{
		Type: "error",
		Text: errorMsg,
	}
	s.sendMessage(msg)
}