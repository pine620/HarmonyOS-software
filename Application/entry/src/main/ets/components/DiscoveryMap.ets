import { FeaturePerformanceTrace } from '../service/FeaturePerformanceTrace';
import { common } from '@kit.AbilityKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { MapComponent, map, mapCommon } from '@kit.MapKit';
import { DiscoveryCamera, DiscoveryViewport, MapMerchant } from '../model/DiscoveryModels';
import { LocationService } from '../service/LocationService';
import { ErrorDetail, errorText } from '../common/ErrorKit';

interface MerchantMarker { merchantId: string; marker: map.Marker; selected: boolean; }

@Component
export struct DiscoveryMap {
  @Prop @Watch('onMerchantsChanged') merchants: Array<MapMerchant> = [];
  @Prop @Watch('onSelectionChanged') selectedMerchantId: string = '';
  @Prop @Watch('onCameraChanged') camera: DiscoveryCamera = { latitude: 39.9, longitude: 116.4, zoom: 15 };
  @Prop @Watch('onSizeChanged') expanded: boolean = false;
  @Prop dirty: boolean = false;
  @Prop loading: boolean = false;
  onViewport: (viewport: DiscoveryViewport, camera: DiscoveryCamera) => void = (_viewport: DiscoveryViewport, _camera: DiscoveryCamera): void => {};
  onSelect: (merchant: MapMerchant) => void = (_merchant: MapMerchant): void => {};
  onSearch: () => void = (): void => {};
  onExpand: () => void = (): void => {};
  @State status: string = '正在准备地图，可先浏览推荐。';
  @State ready: boolean = false;
  @State locating: boolean = false;
  private controller: map.MapComponentController | undefined = undefined;
  private events: map.MapEventManager | undefined = undefined;
  private markers: Array<MerchantMarker> = [];
  private markerGeneration: number = 0;
  private selectionRunning: boolean = false;
  private selectionPending: boolean = false;
  private lifetime: number = 0;
  private active: boolean = false;
  private sizeTimer: number | undefined = undefined;
  private options: mapCommon.MapOptions = {
    position: { target: { latitude: 39.9, longitude: 116.4 }, zoom: 15 },
    rotateGesturesEnabled: false, tiltGesturesEnabled: false, scaleControlsEnabled: true
  };
  private renderTrace: number | undefined = undefined;
  private loaded: () => void = (): void => { this.finishRenderTrace(); this.readViewport(); };
  private finishRenderTrace(): void { if (this.renderTrace !== undefined) { FeaturePerformanceTrace.finish('map_first_render', this.renderTrace); this.renderTrace = undefined; } }
  private idle: () => void = (): void => this.readViewport();
  private clicked: (marker: map.Marker) => void = (marker: map.Marker): void => {
    if (!this.active) return;
    const slot: MerchantMarker | undefined = this.markers.find((value: MerchantMarker): boolean => value.marker.getId() === marker.getId());
    if (slot === undefined) return;
    const merchant: MapMerchant | undefined = this.merchants.find((value: MapMerchant): boolean => value.merchantId === slot.merchantId);
    if (merchant !== undefined) this.onSelect(merchant);
  };
  private callback: AsyncCallback<map.MapComponentController> = (error: BusinessError, controller: map.MapComponentController): void => {
    if (!this.active) return;
    if (error !== undefined && error !== null) { this.finishRenderTrace(); this.status = '地图暂不可用，可继续浏览推荐。错误码：' + error.code; return; }
    try {
      this.controller = controller; controller.setMyLocationEnabled(false);
      this.events = controller.getEventManager();
      this.events.on('cameraIdle', this.idle); this.events.on('mapLoad', this.loaded); this.events.on('markerClick', this.clicked);
      this.ready = true; this.status = '默认／上次浏览区域，未主动定位。';
      this.onCameraChanged(); void this.replaceMarkers();
    } catch (failure) { this.finishRenderTrace(); this.status = errorText(failure as ErrorDetail); }
  };
  aboutToAppear(): void {
    this.active = true; this.lifetime++; this.finishRenderTrace(); this.renderTrace = FeaturePerformanceTrace.start('map_first_render');
    const target: mapCommon.LatLng = { latitude: this.camera.latitude, longitude: this.camera.longitude };
    const position: mapCommon.CameraPosition = { target, zoom: this.camera.zoom };
    this.options = { position, rotateGesturesEnabled: false, tiltGesturesEnabled: false, scaleControlsEnabled: true };
  }
  aboutToDisappear(): void {
    this.finishRenderTrace(); this.active = false; this.lifetime++; this.markerGeneration++;
    if (this.sizeTimer !== undefined) clearTimeout(this.sizeTimer);
    const events: map.MapEventManager | undefined = this.events;
    if (events !== undefined) {
      try { events.off('cameraIdle', this.idle); events.off('mapLoad', this.loaded); events.off('markerClick', this.clicked); } catch (_error) { }
    }
    for (const value of this.markers) { try { value.marker.remove(); } catch (_error) { } }
    this.markers = []; this.events = undefined; this.controller = undefined; this.ready = false; this.locating = false;
  }
  private readViewport(): void {
    const controller: map.MapComponentController | undefined = this.controller;
    if (controller === undefined || !this.active) return;
    try {
      const bounds: mapCommon.LatLngBounds = controller.getProjection().getVisibleRegion().bounds;
      const position: mapCommon.CameraPosition = controller.getCameraPosition();
      const viewport: DiscoveryViewport = { north: bounds.northeast.latitude, south: bounds.southwest.latitude,
        east: bounds.northeast.longitude, west: bounds.southwest.longitude };
      const camera: DiscoveryCamera = { latitude: position.target.latitude, longitude: position.target.longitude, zoom: position.zoom };
      this.onViewport(viewport, camera);
    } catch (failure) { this.status = errorText(failure as ErrorDetail); }
  }
  private onCameraChanged(): void {
    const controller: map.MapComponentController | undefined = this.controller;
    if (controller === undefined || !this.active) return;
    const target: mapCommon.LatLng = { latitude: this.camera.latitude, longitude: this.camera.longitude };
    try { controller.moveCamera(map.newLatLng(target, this.camera.zoom)); } catch (failure) { this.status = errorText(failure as ErrorDetail); }
  }
  private onSizeChanged(): void {
    if (this.sizeTimer !== undefined) clearTimeout(this.sizeTimer);
    this.sizeTimer = setTimeout((): void => { if (this.active) this.readViewport(); }, 100);
  }
  private onMerchantsChanged(): void { void this.replaceMarkers(); }
  private onSelectionChanged(): void { void this.updateSelection(); }
  private async updateSelection(): Promise<void> {
    this.selectionPending = true;
    if (this.selectionRunning) return;
    this.selectionRunning = true;
    try {
      while (this.active && this.selectionPending) {
        this.selectionPending = false;
        const generation: number = this.markerGeneration;
        for (const slot of this.markers) {
          if (!this.active || generation !== this.markerGeneration) break;
          const selected: boolean = slot.merchantId === this.selectedMerchantId;
          if (slot.selected === selected) continue;
          try {
            await slot.marker.setIcon(selected ? $r('app.media.map_marker_selected') : $r('app.media.map_marker'));
            if (!this.active || generation !== this.markerGeneration) break;
            slot.selected = selected; slot.marker.setZIndex(selected ? 2 : 1);
            if (selected !== (slot.merchantId === this.selectedMerchantId)) this.selectionPending = true;
          } catch (_error) { }
        }
      }
    } finally { this.selectionRunning = false; }
  }
  private async replaceMarkers(): Promise<void> {
    const controller: map.MapComponentController | undefined = this.controller;
    if (controller === undefined || !this.active) return;
    const generation: number = ++this.markerGeneration;
    for (const slot of this.markers) { try { slot.marker.remove(); } catch (_error) { } }
    this.markers = [];
    for (const merchant of this.merchants) {
      if (!this.active || generation !== this.markerGeneration) return;
      const position: mapCommon.LatLng = { latitude: merchant.latitude, longitude: merchant.longitude };
      const selected: boolean = merchant.merchantId === this.selectedMerchantId;
      const options: mapCommon.MarkerOptions = { position, title: merchant.name, clickable: true,
        icon: selected ? $r('app.media.map_marker_selected') : $r('app.media.map_marker') };
      try {
        const marker: map.Marker = await controller.addMarker(options);
        if (!this.active || generation !== this.markerGeneration) { marker.remove(); return; }
        const slot: MerchantMarker = { merchantId: merchant.merchantId, marker, selected }; marker.setZIndex(selected ? 2 : 1); this.markers.push(slot);
      } catch (failure) { if (this.active && generation === this.markerGeneration) this.status = errorText(failure as ErrorDetail); }
    }
    if (this.active && generation === this.markerGeneration) void this.updateSelection();
  }
  private confirmLocation(): void {
    const dialog: AlertDialogParamWithConfirm = { title: '定位到我', message: '仅用于把地图移动到当前位置，不上传设备定位。拒绝授权仍可手动浏览。',
      confirm: { value: '继续定位', action: (): void => { void this.locate(); } } };
    AlertDialog.show(dialog);
  }
  private async locate(): Promise<void> {
    if (this.locating || !this.ready) return;
    const generation: number = this.lifetime; this.locating = true;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const point: mapCommon.LatLng = await LocationService.getMapLocation(context);
      if (!this.active || generation !== this.lifetime) return;
      const controller: map.MapComponentController | undefined = this.controller;
      if (controller !== undefined) controller.moveCamera(map.newLatLng(point, 16));
      this.status = '已移动到当前位置，点击搜索此区域更新结果。';
    } catch (failure) { if (this.active && generation === this.lifetime) this.status = errorText(failure as ErrorDetail); }
    finally { if (this.active && generation === this.lifetime) this.locating = false; }
  }
  build() {
    Stack({ alignContent: Alignment.Top }) {
      MapComponent({ mapOptions: this.options, mapCallback: this.callback }).width('100%').height('100%')
      Column() {
        Row() {
          Button(this.loading ? '正在搜索…' : this.dirty ? '搜索此区域' : '刷新此区域')
            .height(48).enabled(this.ready && !this.loading).fontSize(14)
            .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
            .onClick((): void => this.onSearch())
          Blank()
          Button(this.expanded ? '收起地图' : '展开地图').height(48).fontSize(12)
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink')).onClick((): void => this.onExpand())
        }.width('100%')
        Blank()
        Row() {
          Text(this.status).fontSize(12).fontColor($r('app.color.ink')).maxLines(2).layoutWeight(1)
          Button(this.locating ? '定位中…' : '定位到我').height(48).enabled(this.ready && !this.locating).fontSize(12)
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action')).onClick((): void => this.confirmLocation())
        }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(10)
      }.height('100%').width('100%').padding(8).hitTestBehavior(HitTestMode.Transparent)
    }.width('100%').height('100%').clip(true).borderRadius(16)
  }
}
