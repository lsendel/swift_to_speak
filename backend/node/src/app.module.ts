import { Module } from '@nestjs/common';
import { VoiceGateway } from './gateways/voice.gateway';
import { PipelineService } from './services/pipeline.service';
import { ProviderService } from './services/provider.service';
import { DeepgramService } from './providers/deepgram.service';
import { ElevenLabsService } from './providers/elevenlabs.service';
import { XAIService } from './providers/xai.service';
import { AudioProcessor } from './audio/audio-processor';
import { VoiceActivityDetector } from './audio/vad';
import { SessionManager } from './services/session-manager';
import { MetricsService } from './services/metrics.service';
import { DatabaseModule } from './database/database.module';
import { RedisModule } from './redis/redis.module';

@Module({
  imports: [DatabaseModule, RedisModule],
  providers: [
    VoiceGateway,
    PipelineService,
    ProviderService,
    DeepgramService,
    ElevenLabsService,
    XAIService,
    AudioProcessor,
    VoiceActivityDetector,
    SessionManager,
    MetricsService,
  ],
})
export class AppModule {}