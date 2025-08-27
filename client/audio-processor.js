// AudioWorklet processor for capturing and converting audio to PCM16
class AudioProcessor extends AudioWorkletProcessor {
    constructor() {
        super();
        this.bufferSize = 1024; // Buffer size for accumulating samples
        this.buffer = new Float32Array(this.bufferSize);
        this.bufferIndex = 0;
    }

    // Convert Float32 samples to Int16 PCM
    float32ToInt16(float32Array) {
        const int16Array = new Int16Array(float32Array.length);
        for (let i = 0; i < float32Array.length; i++) {
            // Clamp the value between -1 and 1
            let s = Math.max(-1, Math.min(1, float32Array[i]));
            // Convert to 16-bit signed integer
            int16Array[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
        }
        return int16Array;
    }

    process(inputs, outputs, parameters) {
        const input = inputs[0];
        
        if (input.length > 0) {
            // For stereo, we need to interleave the channels
            const channel0 = input[0]; // Left channel
            const channel1 = input.length > 1 ? input[1] : input[0]; // Right channel (duplicate left if mono)
            
            // Interleave samples from both channels
            for (let i = 0; i < channel0.length; i++) {
                this.buffer[this.bufferIndex++] = channel0[i];
                
                // When buffer is full, convert and send
                if (this.bufferIndex >= this.bufferSize) {
                    // Convert Float32 to Int16 PCM
                    const int16Buffer = this.float32ToInt16(this.buffer);
                    
                    // For stereo, we need to create an interleaved buffer
                    const stereoBuffer = new Int16Array(int16Buffer.length * 2);
                    for (let j = 0; j < int16Buffer.length; j++) {
                        stereoBuffer[j * 2] = int16Buffer[j];     // Left channel
                        stereoBuffer[j * 2 + 1] = int16Buffer[j]; // Right channel (duplicate for now)
                    }
                    
                    // Send as ArrayBuffer (little-endian by default)
                    this.port.postMessage({
                        type: 'audio',
                        buffer: stereoBuffer.buffer
                    });
                    
                    // Reset buffer
                    this.bufferIndex = 0;
                }
            }
        }
        
        return true; // Keep processor alive
    }
}

// Register the processor
registerProcessor('audio-processor', AudioProcessor);