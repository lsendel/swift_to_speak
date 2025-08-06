import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { IoAdapter } from '@nestjs/platform-socket.io';
import { Logger } from '@nestjs/common';
import * as dotenv from 'dotenv';

dotenv.config();

const logger = new Logger('VoiceFlowAI');

async function bootstrap() {
  const app = await NestFactory.create(AppModule, {
    logger: ['error', 'warn', 'log', 'debug', 'verbose'],
    cors: {
      origin: ['http://localhost:3000', 'voiceflow-ai://', 'https://voiceflow-ai.com'],
      credentials: true,
    },
  });

  app.useWebSocketAdapter(new IoAdapter(app));
  
  const port = process.env.PORT || 3001;
  await app.listen(port);
  
  logger.log(`🚀 Voice Gateway running on port ${port}`);
  logger.log(`📡 WebSocket endpoint: ws://localhost:${port}`);
  logger.log(`🔊 Audio pipeline ready`);
}

bootstrap().catch((error) => {
  logger.error('Failed to start server:', error);
  process.exit(1);
});