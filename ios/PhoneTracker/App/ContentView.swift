import SwiftUI
import UIKit

private let blue = Color(brandBlue)
private let ink = Color(red: 30 / 255, green: 41 / 255, blue: 59 / 255)
private let pale = Color(red: 239 / 255, green: 246 / 255, blue: 255 / 255)

struct PillButton: View {
  let title: String
  var selected = false
  var enabled = true
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 48)
        .foregroundStyle(selected ? Color.white : blue)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? blue : pale))
    }
    .buttonStyle(.plain)
    .disabled(!enabled).opacity(enabled ? 1 : 0.45)
    .accessibilityLabel(title)
  }
}

struct ContentView: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var rangeStart = Date()
  @State private var rangeEnd = Date()

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        if model.canGoBack {
          PillButton(title: "返回") { model.navigateBack() }.frame(width: 72).padding(.leading, 8)
        }
        Text("PhoneTracker").font(.system(size: 24, weight: .bold)).foregroundStyle(ink)
          .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
        Spacer()
      }
      Text(model.statusText).font(.system(size: 14)).foregroundStyle(ink)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 6)
      HStack(spacing: 6) {
        PillButton(title: model.recording ? "停止記錄" : "開始記錄") { model.toggleRecording() }
      }.padding(.horizontal, 11).padding(.vertical, 4)
      HStack(spacing: 6) {
        ForEach(Array([(AppModel.Mode.live, "即時位置"), (.history, "歷史軌跡")].enumerated()), id: \.offset) { _, tab in
          PillButton(title: tab.1, selected: model.mode == tab.0) { model.selectTab(tab.0) }
        }
        PillButton(title: "匯出地圖") { model.exportMap() }
      }.padding(.horizontal, 11).padding(.vertical, 4)
      if model.mode == .history {
        HStack(spacing: 6) {
          ForEach([Int64(1), 3, 6], id: \.self) { duration in
            PillButton(title: "\(duration) 小時", selected: model.customStart == nil && model.hours == duration) { model.selectRange(duration) }
              .accessibilityLabel("最近 \(duration) 小時")
          }
          PillButton(title: "指定起訖", selected: model.customStart != nil) {
            rangeStart = model.defaultCustomStart; rangeEnd = model.defaultCustomEnd; model.showRangePicker = true
          }
        }.padding(.horizontal, 11).padding(.vertical, 4)
      }
      Text(model.detailText).font(.system(size: 12)).foregroundStyle(ink)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 6)
      ZStack(alignment: .bottomTrailing) {
        MapViewHost(controller: model.map)
        VStack(spacing: 1) {
          Button { model.map.zoomBy(1) } label: { Image(systemName: "plus").frame(width: 40, height: 40) }
            .accessibilityLabel("放大")
          Button { model.map.zoomBy(-1) } label: { Image(systemName: "minus").frame(width: 40, height: 40) }
            .accessibilityLabel("縮小")
        }
        .foregroundStyle(ink).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(12).padding(.bottom, 24)
      }
      if model.mode == .history {
        VStack(alignment: .leading, spacing: 0) {
          Text(model.playbackLabel).font(.system(size: 12)).foregroundStyle(ink).padding(.top, 6)
          HStack(spacing: 6) {
            PillButton(title: model.playing ? "暫停" : "播放", enabled: model.playEnabled) { model.togglePlay() }.frame(width: 72)
            Slider(value: Binding(get: { model.sliderProgress }, set: { model.setSlider($0) }), in: 0...1000,
                   onEditingChanged: { model.sliderEditing($0) })
              .disabled(!model.playEnabled).accessibilityLabel("歷史回放時間")
            PillButton(title: "完整軌跡") { model.fullTrack() }.frame(width: 88)
          }.padding(.vertical, 4)
        }.padding(.horizontal, 12)
      }
    }
    .background(Color(red: 248 / 255, green: 250 / 255, blue: 252 / 255).ignoresSafeArea())
    .overlay(alignment: .bottom) {
      if let toast = model.toast {
        Text(toast).font(.subheadline).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10)
          .background(Capsule().fill(Color.black.opacity(0.8))).padding(.bottom, 90).transition(.opacity)
      }
    }
    .animation(.default, value: model.toast)
    .onChange(of: scenePhase, initial: true) { _, phase in model.setActive(phase == .active) }
    .alert("請開啟定位", isPresented: $model.gpsAlert) {
      Button("開啟設定") { openSettings() }
      Button("取消", role: .cancel) {}
    } message: { Text("手機位置記錄需要精確位置與手機定位服務。請到「設定 › 隱私權與安全性 › 定位服務」開啟。") }
    .alert("需要精確位置", isPresented: Binding(get: { model.settingsAlert != nil }, set: { if !$0 { model.settingsAlert = nil } })) {
      Button("開啟設定") { openSettings() }
      Button("取消", role: .cancel) {}
    } message: { Text(model.settingsAlert ?? "") }
    .sheet(isPresented: $model.showRangePicker) { rangePicker }
    .confirmationDialog("匯出地圖圖片", isPresented: $model.showExportOptions, titleVisibility: .visible) {
      // Present after the dialog has finished closing; SwiftUI drops a sheet requested mid-dismissal.
      Button("儲存圖片") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.showSave = true } }
      Button("分享圖片") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.shareExport() } }
      Button("取消", role: .cancel) {}
    }
    .fileExporter(isPresented: $model.showSave, document: model.showSave ? model.exportFile.flatMap { try? PNGFile(url: $0) } : nil,
                  contentType: .png, defaultFilename: model.exportFile?.deletingPathExtension().lastPathComponent) { result in
      switch result {
      case .success: model.show("地圖圖片已儲存")
      case .failure(let error as CocoaError) where error.code == .userCancelled: break
      case .failure: model.show("儲存圖片失敗，請重試")
      }
    }
  }

  private var rangePicker: some View {
    NavigationStack {
      Form {
        DatePicker("開始時間", selection: $rangeStart, displayedComponents: [.date, .hourAndMinute])
        DatePicker("結束時間", selection: $rangeEnd, displayedComponents: [.date, .hourAndMinute])
        Text("結束須晚於開始，最長 240 小時").font(.footnote).foregroundStyle(.secondary)
      }
      .environment(\.locale, Locale(identifier: "zh_TW"))
      .navigationTitle("指定起訖").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { model.showRangePicker = false } }
        ToolbarItem(placement: .confirmationAction) {
          Button("確定") { model.showRangePicker = false; model.applyCustomRange(start: rangeStart, end: rangeEnd) }
        }
      }
    }
    .presentationDetents([.medium])
  }

  private func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
  }
}
