import { EmptyRequest } from '../model/CloudContracts';
import { Stage47Capabilities } from '../model/FeatureModels';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { AuthService } from '../service/AuthService';
import { ReadRequestOptions, ReadScheduler } from '../service/ReadScheduler';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { CloudGateway } from '../service/CloudGateway';

export class FeatureRepository {
  private static capabilitiesKey: string = '';
  private static capabilitiesUntil: number = 0;
  private static capabilitiesValue: Stage47Capabilities | undefined = undefined;
  private static capabilitiesPending: Promise<Stage47Capabilities> | undefined = undefined;

  async capabilities(): Promise<Stage47Capabilities> {
    const owner: string = AuthService.profile()?.uid || '';
    const session: number = AuthSessionStore.generation();
    const revision: number = AppStorage.get<number>('accountContentRevision') || 0;
    const lifecycle: number = ReadScheduler.lifecycleRevision();
    const key: string = `${owner}:${session}:${revision}:${lifecycle}`;
    if (key !== FeatureRepository.capabilitiesKey) {
      FeatureRepository.capabilitiesKey = key; FeatureRepository.capabilitiesValue = undefined;
      FeatureRepository.capabilitiesPending = undefined; FeatureRepository.capabilitiesUntil = 0;
    }
    const cached: Stage47Capabilities | undefined = FeatureRepository.capabilitiesValue;
    if (cached !== undefined && Date.now() < FeatureRepository.capabilitiesUntil && AppStorage.get<boolean>('stage47AppActive') !== false) return cached;
    const pending: Promise<Stage47Capabilities> | undefined = FeatureRepository.capabilitiesPending;
    if (pending !== undefined) return pending;
    const request: EmptyRequest = {};
    const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> =>
      owner === (AuthService.profile()?.uid || '') && session === AuthSessionStore.generation() &&
      revision === (AppStorage.get<number>('accountContentRevision') || 0) && lifecycle === ReadScheduler.lifecycleRevision() &&
      AppStorage.get<boolean>('stage47AppActive') !== false };
    const promise: Promise<Stage47Capabilities> = (CloudGateway.hasSession() ?
      AccountRequestGuard.authenticated<Stage47Capabilities>('get-stage47-capabilities', request, options) :
      AccountRequestGuard.public<Stage47Capabilities>('get-stage47-capabilities', request, options))
      .then((value: Stage47Capabilities): Stage47Capabilities => {
        if (FeatureRepository.capabilitiesKey === key) {
          FeatureRepository.capabilitiesValue = value; FeatureRepository.capabilitiesUntil = Date.now() + 15000;
        }
        return value;
      }).finally((): void => { if (FeatureRepository.capabilitiesKey === key) FeatureRepository.capabilitiesPending = undefined; });
    FeatureRepository.capabilitiesPending = promise; return promise;
  }
}
