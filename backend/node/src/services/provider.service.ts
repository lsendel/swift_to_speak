import { Injectable, Logger } from '@nestjs/common';
import { DeepgramService } from '../providers/deepgram.service';
import { GoogleSpeechService } from '../providers/google-speech.service';
import { AzureSpeechService } from '../providers/azure-speech.service';
import { ElevenLabsService } from '../providers/elevenlabs.service';
import { AzureTTSService } from '../providers/azure-tts.service';
import { GoogleTTSService } from '../providers/google-tts.service';
import { XAIService } from '../providers/xai.service';
import { AWSLexService } from '../providers/aws-lex.service';
import { MetricsService } from './metrics.service';

export interface ProviderHealth {
  name: string;
  type: 'stt' | 'tts' | 'ai' | 'conversation';
  status: 'healthy' | 'degraded' | 'unhealthy';
  latency: number;
  successRate: number;
  lastCheck: Date;
  cost: number;
}

export interface AudioConfig {
  sampleRate: number;      // 16000, 22050, 44100, 48000
  bitDepth: number;         // 16, 24, 32
  channels: number;         // 1 (mono), 2 (stereo)
  codec: 'pcm' | 'opus' | 'aac' | 'mp3';
  compression?: number;     // 0-10 for opus
  noiseSupression: boolean;
  echoCancellation: boolean;
  autoGainControl: boolean;
}

export interface NetworkRequirements {
  minBandwidth: number;     // Mbps
  maxLatency: number;       // ms
  jitterTolerance: number;  // ms
  packetLoss: number;       // percentage
  protocol: 'websocket' | 'webrtc' | 'http2';
  qos: 'realtime' | 'interactive' | 'bulk';
}

@Injectable()
export class ProviderService {
  private logger = new Logger('ProviderService');
  private providers = new Map<string, any>();
  private healthStatus = new Map<string, ProviderHealth>();
  private providerConfig = new Map<string, any>();
  
  // Hardware Requirements
  private readonly hardwareRequirements = {
    ios: {
      minVersion: '16.0',
      processor: 'A12 Bionic or later',
      ram: '3GB minimum',
      microphone: 'Built-in or MFi certified',
      audioSession: 'AVAudioSessionCategoryPlayAndRecord',
      sampleRate: 48000,
      bufferSize: 256,
    },
    macos: {
      minVersion: '13.0 Ventura',
      processor: 'M1 or Intel Core i5+',
      ram: '8GB minimum',
      microphone: 'Any Core Audio compatible',
      audioUnit: 'AUHAL',
      sampleRate: 48000,
      bufferSize: 512,
    },
    windows: {
      minVersion: 'Windows 10 1903+',
      processor: 'Intel Core i5 or AMD Ryzen 5',
      ram: '8GB minimum',
      microphone: 'Any WASAPI compatible',
      audioApi: 'WASAPI exclusive mode',
      sampleRate: 48000,
      bufferSize: 480,
    },
  };

  // Network Requirements
  private readonly networkRequirements: NetworkRequirements = {
    minBandwidth: 1.5,      // Mbps
    maxLatency: 50,         // ms
    jitterTolerance: 10,    // ms
    packetLoss: 0.5,        // %
    protocol: 'websocket',
    qos: 'realtime',
  };

  constructor(
    private deepgramService: DeepgramService,
    private googleSpeechService: GoogleSpeechService,
    private azureSpeechService: AzureSpeechService,
    private elevenLabsService: ElevenLabsService,
    private azureTTSService: AzureTTSService,
    private googleTTSService: GoogleTTSService,
    private xaiService: XAIService,
    private awsLexService: AWSLexService,
    private metricsService: MetricsService,
  ) {
    this.initializeProviders();
    this.startHealthMonitoring();
  }

  private initializeProviders() {
    // Speech-to-Text Providers
    this.providers.set('deepgram-stt', {
      service: this.deepgramService,
      type: 'stt',
      priority: 1,
      config: {
        model: 'nova-2',
        language: 'en-US',
        punctuate: true,
        profanityFilter: false,
        redact: [],
        diarize: true,
        multichannel: false,
        alternatives: 3,
        numerals: true,
        search: [],
        replace: [],
        keywords: [],
        interim_results: true,
        endpointing: 100,
        vad_events: true,
        smart_format: true,
      },
    });

    this.providers.set('google-stt', {
      service: this.googleSpeechService,
      type: 'stt',
      priority: 2,
      config: {
        encoding: 'LINEAR16',
        sampleRateHertz: 16000,
        languageCode: 'en-US',
        maxAlternatives: 3,
        profanityFilter: false,
        enableWordTimeOffsets: true,
        enableAutomaticPunctuation: true,
        enableSpokenPunctuation: true,
        enableSpokenEmojis: true,
        model: 'latest_long',
        useEnhanced: true,
        metadata: {
          interactionType: 'VOICE_SEARCH',
          industryNaicsCodeOfAudio: 541511, // Software development
          microphoneDistance: 'NEARFIELD',
          originalMediaType: 'AUDIO',
          recordingDeviceType: 'SMARTPHONE',
          recordingDeviceName: 'iPhone',
        },
      },
    });

    this.providers.set('azure-stt', {
      service: this.azureSpeechService,
      type: 'stt',
      priority: 3,
      config: {
        language: 'en-US',
        format: 'detailed',
        profanity: 'raw',
        requestSnr: true,
        enableDictation: true,
        initialSilenceTimeout: 5000,
        endSilenceTimeout: 1000,
        segmentationSilenceTimeout: 500,
        stablePartialResultThreshold: 3,
        wordLevelTimestamps: true,
        customModels: [],
      },
    });

    // Text-to-Speech Providers
    this.providers.set('elevenlabs-tts', {
      service: this.elevenLabsService,
      type: 'tts',
      priority: 1,
      config: {
        voiceId: 'pNInz6obpgDQGcFmaJgB', // Adam - upbeat voice
        modelId: 'eleven_turbo_v2_5',
        voiceSettings: {
          stability: 0.5,
          similarityBoost: 0.75,
          style: 0.4,
          useSpeakerBoost: true,
        },
        outputFormat: 'pcm_16000',
        optimizeStreamingLatency: 3,
        chunkLengthSchedule: [100, 150, 200, 250],
      },
    });

    this.providers.set('azure-tts', {
      service: this.azureTTSService,
      type: 'tts',
      priority: 2,
      config: {
        voiceName: 'en-US-JennyNeural',
        outputFormat: 'audio-16khz-128kbitrate-mono-mp3',
        style: 'cheerful',
        styleDegree: 1.5,
        pitch: '+5%',
        rate: '+10%',
        volume: '+10%',
        prosody: {
          contour: '(0%,+20Hz) (50%,-10Hz) (100%,+5Hz)',
        },
      },
    });

    this.providers.set('google-tts', {
      service: this.googleTTSService,
      type: 'tts',
      priority: 3,
      config: {
        voice: {
          languageCode: 'en-US',
          name: 'en-US-Studio-O', // Warm, engaging voice
          ssmlGender: 'FEMALE',
        },
        audioConfig: {
          audioEncoding: 'LINEAR16',
          sampleRateHertz: 16000,
          effectsProfileId: ['headphone-class-device'],
          pitch: 2.0,
          speakingRate: 1.1,
          volumeGainDb: 2.0,
        },
      },
    });

    // AI/Conversation Providers
    this.providers.set('xai', {
      service: this.xaiService,
      type: 'ai',
      priority: 1,
      config: {
        model: 'grok-1',
        temperature: 0.8,
        maxTokens: 150,
        topP: 0.9,
        frequencyPenalty: 0.3,
        presencePenalty: 0.3,
        personality: {
          traits: ['witty', 'engaging', 'helpful', 'upbeat'],
          style: 'conversational',
          humor: 'moderate',
          formality: 'casual',
        },
        contextWindow: 128000,
        streamResponse: true,
      },
    });

    this.providers.set('aws-lex', {
      service: this.awsLexService,
      type: 'conversation',
      priority: 1,
      config: {
        botId: 'VOICEFLOW_AI',
        botAliasId: 'PRODUCTION',
        localeId: 'en_US',
        sessionState: {
          dialogAction: {
            type: 'ElicitIntent',
          },
        },
        requestAttributes: {
          'x-amz-lex:channels:platform': 'VoiceFlowAI',
        },
        responseContentType: 'audio/pcm',
        sessionId: null, // Set per session
      },
    });
  }

  async getOptimalProvider(
    type: 'stt' | 'tts' | 'ai' | 'conversation',
    requirements?: Partial<NetworkRequirements>,
  ): Promise<any> {
    const providers = Array.from(this.providers.entries())
      .filter(([_, config]) => config.type === type)
      .sort((a, b) => {
        const healthA = this.healthStatus.get(a[0]);
        const healthB = this.healthStatus.get(b[0]);
        
        // Sort by health status first
        if (healthA?.status !== healthB?.status) {
          const statusOrder = { healthy: 0, degraded: 1, unhealthy: 2 };
          return statusOrder[healthA?.status || 'unhealthy'] - 
                 statusOrder[healthB?.status || 'unhealthy'];
        }
        
        // Then by latency
        if (healthA && healthB) {
          return healthA.latency - healthB.latency;
        }
        
        // Finally by priority
        return a[1].priority - b[1].priority;
      });

    for (const [name, config] of providers) {
      const health = this.healthStatus.get(name);
      
      // Check if provider meets requirements
      if (requirements?.maxLatency && health && health.latency > requirements.maxLatency) {
        continue;
      }
      
      if (health?.status === 'unhealthy') {
        continue;
      }
      
      return config.service;
    }
    
    throw new Error(`No healthy ${type} provider available`);
  }

  async transcribeWithFallback(
    audioBuffer: Buffer,
    sessionId: string,
  ): Promise<{ text: string; confidence: number; provider: string }> {
    const providers = ['deepgram-stt', 'google-stt', 'azure-stt'];
    
    for (const providerName of providers) {
      try {
        const startTime = Date.now();
        const provider = this.providers.get(providerName);
        
        if (!provider) continue;
        
        const result = await this.withTimeout(
          provider.service.transcribe(audioBuffer, provider.config),
          500, // 500ms timeout
        );
        
        const latency = Date.now() - startTime;
        this.updateHealthStatus(providerName, true, latency);
        
        this.logger.log(`Transcription successful with ${providerName} in ${latency}ms`);
        
        return {
          text: result.text,
          confidence: result.confidence || 0.95,
          provider: providerName,
        };
      } catch (error) {
        this.logger.error(`Provider ${providerName} failed:`, error);
        this.updateHealthStatus(providerName, false, 0);
        continue;
      }
    }
    
    throw new Error('All STT providers failed');
  }

  async synthesizeWithFallback(
    text: string,
    sessionId: string,
  ): Promise<{ audio: Buffer; duration: number; provider: string }> {
    const providers = ['elevenlabs-tts', 'azure-tts', 'google-tts'];
    
    for (const providerName of providers) {
      try {
        const startTime = Date.now();
        const provider = this.providers.get(providerName);
        
        if (!provider) continue;
        
        const result = await this.withTimeout(
          provider.service.synthesize(text, provider.config),
          1000, // 1s timeout
        );
        
        const latency = Date.now() - startTime;
        this.updateHealthStatus(providerName, true, latency);
        
        this.logger.log(`TTS successful with ${providerName} in ${latency}ms`);
        
        return {
          audio: result.audio,
          duration: result.duration || this.estimateDuration(text),
          provider: providerName,
        };
      } catch (error) {
        this.logger.error(`Provider ${providerName} failed:`, error);
        this.updateHealthStatus(providerName, false, 0);
        continue;
      }
    }
    
    throw new Error('All TTS providers failed');
  }

  async generateAIResponse(
    text: string,
    context: any[],
    sessionId: string,
  ): Promise<{ text: string; intent?: string; provider: string }> {
    try {
      // Try xAI first for personality
      const xaiResult = await this.withTimeout(
        this.xaiService.generateResponse(text, context),
        2000,
      );
      
      // Use AWS Lex for intent recognition
      const lexResult = await this.awsLexService.recognizeIntent(text, sessionId);
      
      return {
        text: xaiResult.text,
        intent: lexResult.intent,
        provider: 'xai+lex',
      };
    } catch (error) {
      this.logger.error('AI generation failed:', error);
      throw error;
    }
  }

  private updateHealthStatus(
    providerName: string,
    success: boolean,
    latency: number,
  ) {
    const current = this.healthStatus.get(providerName) || {
      name: providerName,
      type: this.providers.get(providerName)?.type,
      status: 'healthy',
      latency: 0,
      successRate: 1.0,
      lastCheck: new Date(),
      cost: 0,
    };
    
    // Update success rate (exponential moving average)
    const alpha = 0.1;
    current.successRate = alpha * (success ? 1 : 0) + (1 - alpha) * current.successRate;
    
    // Update latency (if successful)
    if (success && latency > 0) {
      current.latency = alpha * latency + (1 - alpha) * current.latency;
    }
    
    // Update status
    if (current.successRate > 0.9) {
      current.status = 'healthy';
    } else if (current.successRate > 0.5) {
      current.status = 'degraded';
    } else {
      current.status = 'unhealthy';
    }
    
    current.lastCheck = new Date();
    
    this.healthStatus.set(providerName, current);
    this.metricsService.recordProviderHealth(current);
  }

  private async startHealthMonitoring() {
    setInterval(async () => {
      for (const [name, config] of this.providers.entries()) {
        try {
          const startTime = Date.now();
          await config.service.healthCheck();
          const latency = Date.now() - startTime;
          
          this.updateHealthStatus(name, true, latency);
        } catch (error) {
          this.updateHealthStatus(name, false, 0);
        }
      }
    }, 30000); // Check every 30 seconds
  }

  private async withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
    const timeout = new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error('Operation timed out')), ms),
    );
    return Promise.race([promise, timeout]);
  }

  private estimateDuration(text: string): number {
    // Estimate ~150 words per minute
    const words = text.split(' ').length;
    return (words / 150) * 60 * 1000; // Convert to milliseconds
  }

  getHardwareRequirements(platform: 'ios' | 'macos' | 'windows') {
    return this.hardwareRequirements[platform];
  }

  getNetworkRequirements(): NetworkRequirements {
    return this.networkRequirements;
  }

  getProviderStatus(): ProviderHealth[] {
    return Array.from(this.healthStatus.values());
  }
}