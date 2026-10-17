/**
 * 【文件职责】「食刻推荐」桌面卡片的 FormExtensionAbility（在 module.json5 中注册，配置见 resources/base/profile/form_config.json）。
 * 卡片生命周期回调只读取 ServiceCardStore 中 App 前台准备好的本地数据，绝不发网络请求或执行长任务。
 */
import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { ServiceCardStore } from '../service/ServiceCardStore';
import { isServiceCardRefreshMessage } from '../service/ServiceCardInteraction';

// 从 Want 中取出卡片实例 id。
function formIdentity(want: Want): string {
  if (want.parameters === undefined) return '';
  const value: Object | undefined = want.parameters[formInfo.FormParam.IDENTITY_KEY];
  if (typeof value === 'string') return value;
  if (typeof value === 'number') return value.toString();
  return '';
}

// 从 Want 中取出卡片尺寸。
function formDimension(want: Want): number {
  if (want.parameters === undefined) return formInfo.FormDimension.Dimension_2_2;
  const value: Object | undefined = want.parameters[formInfo.FormParam.DIMENSION_KEY];
  return typeof value === 'number' && value === formInfo.FormDimension.Dimension_2_4
    ? formInfo.FormDimension.Dimension_2_4 : formInfo.FormDimension.Dimension_2_2;
}

// 推荐卡片扩展。
export default class ServiceCardFormAbility extends FormExtensionAbility {
  // 添加卡片：记录实例与尺寸，返回本地绑定数据。
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = formIdentity(want);
    const dimension: number = formDimension(want);
    ServiceCardStore.addFormId(this.context, formId);
    ServiceCardStore.setFormDimension(this.context, formId, dimension);
    return ServiceCardStore.bindingData(this.context, formId, dimension);
  }

  // 临时卡片转为常规卡片：记录实例。
  onCastToNormalForm(formId: string): void {
    ServiceCardStore.addFormId(this.context, formId);
  }

  // 系统请求更新卡片：用本地数据刷新。
  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    // 恢复的卡片可能在本应用重建本地卡片 id 缓存之前就收到更新回调；先记录它，以便已开启远程同步的账号在下次前台同步时登记数据代理订阅。
    ServiceCardStore.addFormId(this.context, formId);
    if (wantParams !== undefined) {
      const dimension: Object | undefined = wantParams[formInfo.FormParam.DIMENSION_KEY];
      if (typeof dimension === 'number' && (dimension === 2 || dimension === 3)) {
        ServiceCardStore.setFormDimension(this.context, formId, dimension);
      }
    }
    this.updateFormData(formId);
  }

  // 卡片尺寸变化（2×2 ↔ 2×4）：记录并刷新。
  onSizeChanged(formId: string, dimension: formInfo.FormDimension, _rect: formInfo.Rect): void {
    ServiceCardStore.setFormDimension(this.context, formId, dimension);
    this.updateFormData(formId);
  }

  // 卡片内按钮事件（刷新）。
  onFormEvent(formId: string, message: string): void {
    if (!isServiceCardRefreshMessage(message)) return;
    // 只重新绑定已有的本地公开摘要；卡片生命周期回调中不能发网络请求或执行长任务。
    this.updateFormData(formId);
  }

  // 用本地数据更新卡片。
  private async updateFormData(formId: string): Promise<void> {
    try {
      await ServiceCardStore.updateForm(this.context, formId);
    } catch (_error) {
      console.warn('Service card update was not completed.');
    }
  }

  // 卡片被移除：清理实例记录。
  onRemoveForm(formId: string): void {
    ServiceCardStore.removeFormId(this.context, formId);
  }

  // 扩展停止：释放初始绑定租约。
  onStop(): void {
    ServiceCardStore.releaseInitialBindings();
  }

  // 卡片状态查询：始终就绪。
  onAcquireFormState(_want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
