// Main application state
let audioContext = null;
let mediaStream = null;
let workletNode = null;
let websocket = null;
let isRecording = false;

// DOM elements
const startBtn = document.getElementById('startBtn');
const stopBtn = document.getElementById('stopBtn');
const statusDiv = document.getElementById('status');
const transcriptionDiv = document.getElementById('transcription');
const savedInfoDiv = document.getElementById('savedInfo');
const savedKeySpan = document.getElementById('savedKey');
const errorMessageDiv = document.getElementById('errorMessage');
const specialtySelect = document.getElementById('specialty');
const typeSelect = document.getElementById('type');

// Event listeners
startBtn.addEventListener('click', startRecording);
stopBtn.addEventListener('click', stopRecording);

// WebSocket URL (backend is exposed on port 8000)
function getWebSocketURL() {
    const specialty = specialtySelect.value;
    const type = typeSelect.value;
    return `ws://98.86.194.149:8000/ws/medical/direct?specialty=${specialty}&type=${type}`;
}

async function startRecording() {
    try {
        errorMessageDiv.textContent = '';
        savedInfoDiv.classList.remove('show');
        
        // Update UI
        startBtn.disabled = true;
        stopBtn.disabled = false;
        specialtySelect.disabled = true;
        typeSelect.disabled = true;
        statusDiv.className = 'status recording';
        statusDiv.textContent = 'Recording in progress...';
        
        // Clear previous transcription
        transcriptionDiv.innerHTML = '';
        
        // Initialize WebSocket
        await initWebSocket();
        
        // Initialize audio capture
        await initAudioCapture();
        
        isRecording = true;
        
    } catch (error) {
        console.error('Failed to start recording:', error);
        showError('Failed to start recording: ' + error.message);
        resetUI();
    }
}

async function stopRecording() {
    try {
        isRecording = false;
        
        // Update UI
        startBtn.disabled = false;
        stopBtn.disabled = true;
        specialtySelect.disabled = false;
        typeSelect.disabled = false;
        statusDiv.className = 'status idle';
        statusDiv.textContent = 'Processing and saving transcription...';
        
        // Send stop command
        if (websocket && websocket.readyState === WebSocket.OPEN) {
            websocket.send(JSON.stringify({
                type: 'control',
                action: 'stop'
            }));
        }
        
        // Clean up audio
        if (workletNode) {
            workletNode.disconnect();
            workletNode = null;
        }
        
        if (mediaStream) {
            mediaStream.getTracks().forEach(track => track.stop());
            mediaStream = null;
        }
        
        if (audioContext) {
            await audioContext.close();
            audioContext = null;
        }
        
    } catch (error) {
        console.error('Failed to stop recording:', error);
        showError('Failed to stop recording: ' + error.message);
    }
}

async function initWebSocket() {
    return new Promise((resolve, reject) => {
        websocket = new WebSocket(getWebSocketURL());
        websocket.binaryType = 'arraybuffer';
        
        websocket.onopen = () => {
            console.log('WebSocket connected');
            resolve();
        };
        
        websocket.onerror = (error) => {
            console.error('WebSocket error:', error);
            reject(new Error('WebSocket connection failed'));
        };
        
        websocket.onclose = () => {
            console.log('WebSocket closed');
            if (isRecording) {
                showError('WebSocket connection lost');
                resetUI();
            }
        };
        
        websocket.onmessage = (event) => {
            try {
                const message = JSON.parse(event.data);
                handleWebSocketMessage(message);
            } catch (error) {
                console.error('Failed to parse WebSocket message:', error);
            }
        };
    });
}

async function initAudioCapture() {
    // Request microphone access
    mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: {
            channelCount: 2,
            sampleRate: 16000,
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true
        }
    });
    
    // Create audio context with 16kHz sample rate
    audioContext = new AudioContext({ sampleRate: 16000 });
    
    // Load and register the audio worklet
    await audioContext.audioWorklet.addModule('audio-processor.js');
    
    // Create audio source and worklet node
    const source = audioContext.createMediaStreamSource(mediaStream);
    workletNode = new AudioWorkletNode(audioContext, 'audio-processor');
    
    // Handle audio data from worklet
    workletNode.port.onmessage = (event) => {
        if (event.data.type === 'audio' && websocket && websocket.readyState === WebSocket.OPEN) {
            // Send raw PCM audio data to WebSocket
            websocket.send(event.data.buffer);
        }
    };
    
    // Connect audio pipeline
    source.connect(workletNode);
    workletNode.connect(audioContext.destination);
}

function handleWebSocketMessage(message) {
    switch (message.type) {
        case 'partial':
            updatePartialTranscript(message.text);
            break;
            
        case 'final':
            addFinalTranscript(message.text);
            break;
            
        case 'saved':
            showSavedInfo(message.key);
            break;
            
        case 'error':
            showError(message.text);
            break;
            
        default:
            console.log('Unknown message type:', message.type);
    }
}

function updatePartialTranscript(text) {
    // Remove existing partial transcript if any
    const existingPartial = transcriptionDiv.querySelector('.transcript-item.partial');
    if (existingPartial) {
        existingPartial.remove();
    }
    
    // Add new partial transcript
    const item = document.createElement('div');
    item.className = 'transcript-item partial';
    item.textContent = text;
    transcriptionDiv.appendChild(item);
    
    // Auto-scroll to bottom
    transcriptionDiv.scrollTop = transcriptionDiv.scrollHeight;
}

function addFinalTranscript(text) {
    // Remove any existing partial transcript
    const existingPartial = transcriptionDiv.querySelector('.transcript-item.partial');
    if (existingPartial) {
        existingPartial.remove();
    }
    
    // Add final transcript
    const item = document.createElement('div');
    item.className = 'transcript-item final';
    item.textContent = text;
    transcriptionDiv.appendChild(item);
    
    // Auto-scroll to bottom
    transcriptionDiv.scrollTop = transcriptionDiv.scrollHeight;
}

function showSavedInfo(key) {
    savedKeySpan.textContent = key;
    savedInfoDiv.classList.add('show');
    statusDiv.className = 'status idle';
    statusDiv.textContent = 'Transcription saved successfully!';
    
    // Close WebSocket after save
    if (websocket) {
        websocket.close();
        websocket = null;
    }
}

function showError(message) {
    errorMessageDiv.textContent = message;
    statusDiv.className = 'status error';
    statusDiv.textContent = 'Error occurred';
}

function resetUI() {
    isRecording = false;
    startBtn.disabled = false;
    stopBtn.disabled = true;
    specialtySelect.disabled = false;
    typeSelect.disabled = false;
    
    // Clean up resources
    if (workletNode) {
        workletNode.disconnect();
        workletNode = null;
    }
    
    if (mediaStream) {
        mediaStream.getTracks().forEach(track => track.stop());
        mediaStream = null;
    }
    
    if (audioContext) {
        audioContext.close();
        audioContext = null;
    }
    
    if (websocket) {
        websocket.close();
        websocket = null;
    }
}
