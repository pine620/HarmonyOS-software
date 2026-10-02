import { common } from '@kit.AbilityKit';
import { OperationResponse } from '../model/CloudContracts';
import {
  NotificationIdRequest, NotificationPageRequest, NotificationsResponse, OpenNotificationResponse
} from '../model/NotificationModels';
import { AuthService } from '../service/AuthService';
import { CloudGateway } from '../service/CloudGateway';

export class NotificationRepository {
  async list(context: common.Context, pageToken: string = '', pageSize: number = 20): Promise<NotificationsResponse> {
    await AuthService.ensureSession(context);
    const request: NotificationPageRequest = { pageToken, pageSize };
    return CloudGateway.callAuthenticated<NotificationsResponse>('list-notifications', request);
  }

  async markRead(context: common.Context, notificationId: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: NotificationIdRequest = { notificationId };
    const result: OperationResponse =
      await CloudGateway.callAuthenticated<OperationResponse>('mark-notification-read', request);
    if (!result.success) throw new Error('云端未确认通知已读。');
  }

  async markAllRead(context: common.Context): Promise<void> {
    await AuthService.ensureSession(context);
    const request: Record<string, string> = {};
    const result: OperationResponse =
      await CloudGateway.callAuthenticated<OperationResponse>('mark-all-notifications-read', request);
    if (!result.success) throw new Error('云端未确认通知已读。');
  }

  async open(context: common.Context, notificationId: string): Promise<OpenNotificationResponse> {
    await AuthService.ensureSession(context);
    const request: NotificationIdRequest = { notificationId };
    return CloudGateway.callAuthenticated<OpenNotificationResponse>('open-notification', request);
  }
}
