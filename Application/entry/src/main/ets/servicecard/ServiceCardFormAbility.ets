import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { ServiceCardStore } from '../service/ServiceCardStore';
import { SERVICE_CARD_REFRESH_MESSAGE } from '../service/ServiceCardInteraction';

function formIdentity(want: Want): string {
  if (want.parameters === undefined) return '';
  const value: Object | undefined = want.parameters[formInfo.FormParam.IDENTITY_KEY];
  if (typeof value === 'string') return value;
  if (typeof value === 'number') return value.toString();
  return '';
}

export default class ServiceCardFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = formIdentity(want);
    ServiceCardStore.addFormId(this.context, formId);
    return ServiceCardStore.bindingData(this.context, formId);
  }

  onCastToNormalForm(formId: string): void {
    ServiceCardStore.addFormId(this.context, formId);
  }

  onUpdateForm(formId: string): void {
    // A restored card may receive an update callback before this application's
    // local form-ID cache is rebuilt. Retain it so an opted-in account can
    // register the data-proxy subscriber on the next foreground sync.
    ServiceCardStore.addFormId(this.context, formId);
    this.updateFormData(formId);
  }

  onFormEvent(formId: string, message: string): void {
    if (message !== SERVICE_CARD_REFRESH_MESSAGE) return;
    // Only rebind the existing public local summary. Do not start a network
    // request or a long-running task inside the form lifecycle callback.
    this.updateFormData(formId);
  }

  private async updateFormData(formId: string): Promise<void> {
    try {
      await formProvider.updateForm(formId, ServiceCardStore.bindingData(this.context, formId));
    } catch (_error) {
      console.warn('Service card update was not completed.');
    }
  }

  onRemoveForm(formId: string): void {
    ServiceCardStore.removeFormId(this.context, formId);
  }

  onAcquireFormState(_want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
