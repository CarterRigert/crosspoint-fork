import AppKit
import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      header
      Divider()
      controls
      Divider()
      deviceControls
      Divider()
      outputSummary
      Spacer(minLength: 0)
      footer
    }
    .padding(24)
    .onAppear {
      model.bootstrap()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("X4 Sync Server")
            .font(.system(size: 28, weight: .semibold))
          Text("Generates and serves the files your CrossPoint X4 pulls on startup.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Circle()
          .fill(model.serverEnabled ? Color.green : Color.secondary.opacity(0.35))
          .frame(width: 14, height: 14)
          .accessibilityLabel(model.serverEnabled ? "Server running" : "Server stopped")
      }

      HStack(spacing: 8) {
        Text(model.serverURL)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .padding(.vertical, 6)
          .padding(.horizontal, 8)
          .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

        Button {
          model.copyServerURL()
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(model.serverURL.isEmpty)
      }
    }
  }

  private var controls: some View {
    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 14) {
      GridRow {
        Toggle("Server", isOn: Binding(get: { model.serverEnabled }, set: { model.setServerEnabled($0) }))
        Text(model.serverEnabled ? "Listening on port \(model.port)" : "Stopped")
          .foregroundStyle(.secondary)
      }

      GridRow {
        Toggle("Serve with display off", isOn: Binding(get: { model.keepAwakeEnabled }, set: { model.setKeepAwakeEnabled($0) }))
        Text(model.keepAwakeEnabled && model.serverEnabled ? "Display can sleep" : "Normal sleep")
          .foregroundStyle(.secondary)
      }

      GridRow {
        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLoginEnabled($0) }))
        Text(model.launchAtLoginEnabled ? "Starts after Mac login" : "Manual launch")
          .foregroundStyle(.secondary)
      }

      GridRow {
        Toggle("Sleep screen", isOn: $model.sleepEnabled)
        HStack {
          Button {
            model.regenerateSleepScreen()
          } label: {
            Label("Regenerate", systemImage: "photo")
          }
          .disabled(!model.sleepEnabled || model.isBusy)

          Button {
            model.openInputsFolder()
          } label: {
            Label("Inputs", systemImage: "folder")
          }

          Picker("Orientation", selection: $model.sleepOrientation) {
            ForEach(SleepTextOrientation.allCases) { orientation in
              Text(orientation.label).tag(orientation)
            }
          }
          .pickerStyle(.menu)
          .frame(width: 170)
          .disabled(!model.sleepEnabled || model.isBusy)
        }
      }

      GridRow {
        Text("Sleep sections")
        HStack(spacing: 12) {
          Toggle("Weather", isOn: $model.sleepWeatherEnabled)
          Toggle("Calendar", isOn: $model.sleepCalendarEnabled)
          Toggle("Todo", isOn: $model.sleepTodoEnabled)
          Toggle("Notes", isOn: $model.sleepNotesEnabled)
          Toggle("HN", isOn: $model.sleepHNEnabled)
        }
        .disabled(!model.sleepEnabled || model.isBusy)
      }

      GridRow {
        Text("HN on sleep")
        Stepper(value: $model.sleepHNStoryCount, in: 1...10) {
          Text("\(model.sleepHNStoryCount) stor\(model.sleepHNStoryCount == 1 ? "y" : "ies")")
        }
        .disabled(!model.sleepEnabled || !model.sleepHNEnabled || model.isBusy)
      }

      GridRow {
        Toggle("Sleep refresh timer", isOn: $model.sleepRegenerateTimerEnabled)
        Stepper(value: $model.sleepRegenerateIntervalMinutes, in: 5...240, step: 5) {
          Text("Every \(model.sleepRegenerateIntervalMinutes) min")
        }
        .disabled(!model.sleepEnabled || !model.sleepRegenerateTimerEnabled)
      }

      GridRow {
        Toggle("HN Latest EPUB", isOn: $model.hnEnabled)
        HStack(spacing: 12) {
          Stepper(value: $model.hnIntervalMinutes, in: 15...360, step: 15) {
            Text("Every \(model.hnIntervalMinutes) min")
          }
          Button {
            model.updateHNNow()
          } label: {
            Label("Update Now", systemImage: "arrow.clockwise")
          }
          .disabled(!model.hnEnabled || model.isBusy)
        }
      }
    }
    .toggleStyle(.switch)
    .onChange(of: model.sleepEnabled) { _, _ in model.settingsChanged() }
    .onChange(of: model.sleepOrientation) { _, _ in model.sleepOrientationChanged() }
    .onChange(of: model.sleepWeatherEnabled) { _, _ in model.sleepSectionSettingsChanged() }
    .onChange(of: model.sleepCalendarEnabled) { _, _ in model.sleepSectionSettingsChanged() }
    .onChange(of: model.sleepTodoEnabled) { _, _ in model.sleepSectionSettingsChanged() }
    .onChange(of: model.sleepNotesEnabled) { _, _ in model.sleepSectionSettingsChanged() }
    .onChange(of: model.sleepHNEnabled) { _, _ in model.sleepSectionSettingsChanged() }
    .onChange(of: model.sleepHNStoryCount) { _, _ in model.sleepHNStoryCountChanged() }
    .onChange(of: model.sleepRegenerateTimerEnabled) { _, _ in model.sleepTimerSettingsChanged() }
    .onChange(of: model.sleepRegenerateIntervalMinutes) { _, _ in model.sleepTimerSettingsChanged() }
    .onChange(of: model.hnEnabled) { _, _ in model.settingsChanged() }
    .onChange(of: model.hnIntervalMinutes) { _, _ in model.settingsChanged() }
  }

  private var outputSummary: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Output")
        .font(.headline)

      HStack(spacing: 24) {
        statusItem("Manifest", model.manifestStatus)
        statusItem("Sleep BMP", model.sleepStatus)
        statusItem("Sleep Regen", model.sleepRegenerationStatus)
        statusItem("HN EPUB", model.hnStatus)
      }

      HStack(spacing: 8) {
        Text("Sleep API")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(width: 78, alignment: .leading)
        Text("GET \(model.sleepTriggerURL)")
          .font(.system(.body, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        Button {
          model.copySleepTriggerURL()
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(model.serverURL.isEmpty)
      }

      statusItem("Last Request", model.lastRequestStatus)
    }
  }

  private var deviceControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Device")
        .font(.headline)

      HStack(spacing: 12) {
        statusItem("USB", model.deviceStatus)

        Button {
          model.refreshDeviceConnection()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(model.isBusy)

        Button {
          model.pushServerURLToDevice()
        } label: {
          Label("Push Sync URL", systemImage: "link")
        }
        .disabled(model.devicePort == nil || model.serverURL.isEmpty || model.isBusy)

        Button {
          model.flashConnectedX4()
        } label: {
          Label("Flash Firmware", systemImage: "bolt")
        }
        .disabled(model.devicePort == nil || model.isBusy)
      }
    }
  }

  private func statusItem(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var footer: some View {
    HStack {
      Text(model.statusMessage)
        .foregroundStyle(model.lastError == nil ? Color.secondary : Color.red)
        .lineLimit(2)

      Spacer()

      if model.isBusy {
        ProgressView()
          .controlSize(.small)
      }

      Button {
        model.openPublicFolder()
      } label: {
        Label("Served Files", systemImage: "externaldrive")
      }
    }
  }
}
