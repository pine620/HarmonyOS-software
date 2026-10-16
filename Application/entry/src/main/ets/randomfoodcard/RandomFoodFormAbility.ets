import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { RandomFoodWidgetStore } from '../service/RandomFoodWidgetStore';

function formIdentity(want: Want): string {
  if (want.parameters === undefined) return '';
  const value: Object | undefined = want.parameters[formInfo.FormParam.IDENTITY_KEY];
  if (typeof value === 'string') return value;
  if (typeof value === 'number') return value.toString();
  return '';
}

// 「今日吃什么」2×2 card. Only reads the local pool prepared by the app; never starts a network request.
export default class RandomFoodFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = formIdentity(want);
    RandomFoodWidgetStore.addFormId(this.context, formId);
    return RandomFoodWidgetStore.bindingData(this.context, formId);
  }

  onCastToNormalForm(formId: string): void {
    RandomFoodWidgetStore.addFormId(this.context, formId);
  }

  onUpdateForm(formId: string, _wantParams?: Record<string, Object>): void {
    RandomFoodWidgetStore.addFormId(this.context, formId);
    void RandomFoodWidgetStore.updateForm(this.context, formId).catch((): void => {});
  }

  onFormEvent(_formId: string, message: string): void {
    if (!RandomFoodWidgetStore.isFlipMessage(message)) return;
    void RandomFoodWidgetStore.flip(this.context).catch((): void => {});
  }

  onRemoveForm(formId: string): void {
    RandomFoodWidgetStore.removeFormId(this.context, formId);
  }

  onStop(): void {
    RandomFoodWidgetStore.releaseInitialBindings();
  }

  onAcquireFormState(_want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
