import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { ServiceCardStore } from '../service/ServiceCardStore';
import { isServiceCardRefreshMessage } from '../service/ServiceCardInteraction';

function formIdentity(want: Want): string {
  if (want.parameters === undefined) return '';
  const value: Object | undefined = want.parameters[formInfo.FormParam.IDENTITY_KEY];
  if (typeof value === 'string') return value;
  if (typeof value === 'number') return value.toString();
  return '';
}

function formDimension(want: Want): number {
  if (want.parameters === undefined) return formInfo.FormDimension.Dimension_2_2;
  const value: Object | undefined = want.parameters[formInfo.FormParam.DIMENSION_KEY];
  return typeof value === 'number' && value === formInfo.FormDimension.Dimension_2_4
    ? formInfo.FormDimension.Dimension_2_4 : formInfo.FormDimension.Dimension_2_2;
}

export default class ServiceCardFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = formIdentity(want);
    const dimension: number = formDimension(want);
    ServiceCardStore.addFormId(this.context, formId);
    ServiceCardStore.setFormDimension(this.context, formId, dimension);
    return ServiceCardStore.bindingData(this.context, formId, dimension);
  }

  onCastToNormalForm(formId: string): void {
    ServiceCardStore.addFormId(this.context, formId);
  }

  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    // A restored card may receive an update callback before this application's
    // local form-ID cache is rebuilt. Retain it so an opted-in account can
    // register the data-proxy subscriber on the next foreground sync.
    ServiceCardStore.addFormId(this.context, formId);
    if (wantParams !== undefined) {
      const dimension: Object | undefined = wantParams[formInfo.FormParam.DIMENSION_KEY];
      if (typeof dimension === 'number' && (dimension === 2 || dimension === 3)) {
        ServiceCardStore.setFormDimension(this.context, formId, dimension);
      }
    }
    this.updateFormData(formId);
  }

  onSizeChanged(formId: string, dimension: formInfo.FormDimension, _rect: formInfo.Rect): void {
    ServiceCardStore.setFormDimension(this.context, formId, dimension);
    this.updateFormData(formId);
  }

  onFormEvent(formId: string, message: string): void {
    if (!isServiceCardRefreshMessage(message)) return;
    // Only rebind the existing public local summary. Do not start a network
    // request or a long-running task inside the form lifecycle callback.
    this.updateFormData(formId);
  }

  private async updateFormData(formId: string): Promise<void> {
    try {
      await ServiceCardStore.updateForm(this.context, formId);
    } catch (_error) {
      console.warn('Service card update was not completed.');
    }
  }

  onRemoveForm(formId: string): void {
    ServiceCardStore.removeFormId(this.context, formId);
  }

  onStop(): void {
    ServiceCardStore.releaseInitialBindings();
  }

  onAcquireFormState(_want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
