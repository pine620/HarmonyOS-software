import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { RandomFoodWidgetStore } from '../service/RandomFoodWidgetStore';

// 从 Want 中取出卡片实例 id。
function formIdentity(want: Want): string {
  if (want.parameters === undefined) return '';
  const value: Object | undefined = want.parameters[formInfo.FormParam.IDENTITY_KEY];
  if (typeof value === 'string') return value;
  if (typeof value === 'number') return value.toString();
  return '';
}

/**
 * 【文件职责】「今日吃什么」2×2 桌面卡片的 FormExtensionAbility。只读取 App 前台准备好的本地候选池（RandomFoodWidgetStore），绝不发网络请求。
 */
export default class RandomFoodFormAbility extends FormExtensionAbility {
  // 添加卡片：记录实例并返回本地绑定数据。
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = formIdentity(want);
    RandomFoodWidgetStore.addFormId(this.context, formId);
    return RandomFoodWidgetStore.bindingData(this.context, formId);
  }

  // 临时卡片转为常规卡片。
  onCastToNormalForm(formId: string): void {
    RandomFoodWidgetStore.addFormId(this.context, formId);
  }

  // 系统请求更新卡片。
  onUpdateForm(formId: string, _wantParams?: Record<string, Object>): void {
    RandomFoodWidgetStore.addFormId(this.context, formId);
    void RandomFoodWidgetStore.updateForm(this.context, formId).catch((): void => {});
  }

  // 卡片内事件：翻到下一道菜。
  onFormEvent(_formId: string, message: string): void {
    if (!RandomFoodWidgetStore.isFlipMessage(message)) return;
    void RandomFoodWidgetStore.flip(this.context).catch((): void => {});
  }

  // 卡片被移除。
  onRemoveForm(formId: string): void {
    RandomFoodWidgetStore.removeFormId(this.context, formId);
  }

  // 扩展停止：释放初始绑定租约。
  onStop(): void {
    RandomFoodWidgetStore.releaseInitialBindings();
  }

  // 卡片状态查询：始终就绪。
  onAcquireFormState(_want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
