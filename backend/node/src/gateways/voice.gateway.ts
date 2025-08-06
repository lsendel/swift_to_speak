import {
  WebSocketGateway,
  WebSocketServer,
  SubscribeMessage,
  OnGatewayConnection,
  OnGatewayDisconnect,
  MessageBody,
  ConnectedSocket,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { Logger } from '@nestjs/common';
import { PipelineService } from '../services/pipeline.service';
import { SessionManager } from '../services/session-manager';
import { MetricsService } from '../services/metrics.service';

interface AudioChunkMessage {
  sessionId: string;
  audio: ArrayBuffer;
  timestamp: number;
  sequenceNumber: number;
}

interface ControlMessage {
  type: 'start' | 'stop' | 'interrupt' | 'config';
  sessionId?: string;
  userId?: string;
  config?: any;
}

@WebSocketGateway({
  cors: {
    origin: '*',
    credentials: true,
  },
  transports: ['websocket'],
  pingInterval: 25000,
  pingTimeout: 60000,
})
export class VoiceGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server: Server;

  private logger = new Logger('VoiceGateway');
  private activeSessions = new Map<string, string>(); // socketId -> sessionId

  constructor(
    private pipelineService: PipelineService,
    private sessionManager: SessionManager,
    private metricsService: MetricsService,
  ) {}

  async handleConnection(client: Socket) {
    this.logger.log(`Client connected: ${client.id}`);
    this.metricsService.recordConnection();
    
    // Send initial handshake
    client.emit('connected', {
      socketId: client.id,
      timestamp: Date.now(),
      version: '1.0.0',
    });
  }

  async handleDisconnect(client: Socket) {
    this.logger.log(`Client disconnected: ${client.id}`);
    
    const sessionId = this.activeSessions.get(client.id);
    if (sessionId) {
      await this.sessionManager.endSession(sessionId);
      this.activeSessions.delete(client.id);
    }
    
    this.metricsService.recordDisconnection();
  }

  @SubscribeMessage('start-session')
  async handleStartSession(
    @MessageBody() data: ControlMessage,
    @ConnectedSocket() client: Socket,
  ) {
    try {
      const startTime = Date.now();
      
      // Create new session
      const session = await this.sessionManager.createSession({
        userId: data.userId || 'anonymous',
        socketId: client.id,
        config: data.config,
      });
      
      this.activeSessions.set(client.id, session.id);
      
      // Initialize pipeline for this session
      await this.pipelineService.initializePipeline(session.id);
      
      // Send session confirmation
      client.emit('session-started', {
        sessionId: session.id,
        timestamp: Date.now(),
        latency: Date.now() - startTime,
      });
      
      this.logger.log(`Session started: ${session.id} for client: ${client.id}`);
      this.metricsService.recordSessionStart(session.id);
      
    } catch (error) {
      this.logger.error('Failed to start session:', error);
      client.emit('error', {
        type: 'SESSION_START_FAILED',
        message: 'Failed to initialize voice session',
      });
    }
  }

  @SubscribeMessage('audio-chunk')
  async handleAudioChunk(
    @MessageBody() data: AudioChunkMessage,
    @ConnectedSocket() client: Socket,
  ) {
    try {
      const startTime = Date.now();
      
      if (!data.sessionId || !this.activeSessions.has(client.id)) {
        client.emit('error', {
          type: 'NO_SESSION',
          message: 'No active session found',
        });
        return;
      }
      
      // Process audio through pipeline
      const result = await this.pipelineService.processAudioChunk(
        data.sessionId,
        Buffer.from(data.audio),
        data.sequenceNumber,
      );
      
      // Send partial transcript if available
      if (result.partialTranscript) {
        client.emit('transcript', {
          text: result.partialTranscript,
          isFinal: false,
          confidence: result.confidence,
          timestamp: Date.now(),
        });
      }
      
      // Send final transcript and AI response
      if (result.finalTranscript) {
        client.emit('transcript', {
          text: result.finalTranscript,
          isFinal: true,
          confidence: result.confidence,
          timestamp: Date.now(),
        });
        
        // Generate AI response
        const aiResponse = await this.pipelineService.generateResponse(
          data.sessionId,
          result.finalTranscript,
        );
        
        if (aiResponse.audioData) {
          client.emit('audio-response', {
            audio: aiResponse.audioData,
            text: aiResponse.text,
            timestamp: Date.now(),
            duration: aiResponse.duration,
          });
        }
      }
      
      // Record metrics
      const latency = Date.now() - startTime;
      this.metricsService.recordProcessingLatency(data.sessionId, latency);
      
    } catch (error) {
      this.logger.error('Failed to process audio chunk:', error);
      client.emit('error', {
        type: 'PROCESSING_FAILED',
        message: 'Failed to process audio',
      });
    }
  }

  @SubscribeMessage('interrupt')
  async handleInterrupt(
    @MessageBody() data: ControlMessage,
    @ConnectedSocket() client: Socket,
  ) {
    try {
      if (!data.sessionId) return;
      
      await this.pipelineService.interrupt(data.sessionId);
      
      client.emit('interrupted', {
        sessionId: data.sessionId,
        timestamp: Date.now(),
      });
      
      this.logger.log(`Session interrupted: ${data.sessionId}`);
      
    } catch (error) {
      this.logger.error('Failed to interrupt session:', error);
    }
  }

  @SubscribeMessage('end-session')
  async handleEndSession(
    @MessageBody() data: ControlMessage,
    @ConnectedSocket() client: Socket,
  ) {
    try {
      if (!data.sessionId) return;
      
      const stats = await this.sessionManager.getSessionStats(data.sessionId);
      await this.sessionManager.endSession(data.sessionId);
      
      this.activeSessions.delete(client.id);
      
      client.emit('session-ended', {
        sessionId: data.sessionId,
        stats,
        timestamp: Date.now(),
      });
      
      this.logger.log(`Session ended: ${data.sessionId}`);
      this.metricsService.recordSessionEnd(data.sessionId);
      
    } catch (error) {
      this.logger.error('Failed to end session:', error);
    }
  }

  @SubscribeMessage('ping')
  handlePing(@ConnectedSocket() client: Socket) {
    client.emit('pong', { timestamp: Date.now() });
  }
}