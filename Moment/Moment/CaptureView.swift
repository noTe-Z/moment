import SwiftUI
import SwiftData

struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = CaptureViewModel()
    @State private var didBindContext = false
    @State private var gestureActive = false
    @State private var showRepository = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                VStack {
                    Spacer()
                    statusLabel
                        .animation(.easeInOut(duration: 0.2), value: viewModel.status)
                    Spacer()
                    recordButton
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 48)

                repositoryButton
                    .padding()
            }
            .background(Color(.systemBackground))
            .navigationDestination(isPresented: $showRepository) {
                RepositoryView()
            }
        }
        .task {
            await viewModel.prepareSession()
        }
        .onAppear {
            if !didBindContext {
                viewModel.bind(context: modelContext)
                didBindContext = true
            }
        }
        .alert("麦克风权限被拒绝", isPresented: $viewModel.microphoneDenied, actions: {
            Button("好的", role: .cancel) {
                viewModel.handlePermissionDeniedDismissal()
            }
        }, message: {
            Text("请前往系统设置开启麦克风权限，以便记录你的想法。")
        })
        .onDisappear {
            viewModel.cancelActiveRecording()
        }
    }

    private var statusLabel: some View {
        Group {
            switch viewModel.status {
            case .hidden:
                EmptyView()
            case .timer(let text):
                Text(text)
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            case .message(let text):
                Text(text)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(viewModel.status == .hidden ? 0 : 1)
    }

    private var recordButton: some View {
        let isActive = viewModel.isRecording

        return Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(isActive ? 0.85 : 0.7),
                        Color.accentColor
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 220, height: 220)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(isActive ? 0.6 : 0.3), lineWidth: 6)
                    .blur(radius: 0.5)
            )
            .shadow(color: Color.accentColor.opacity(isActive ? 0.45 : 0.2), radius: isActive ? 22 : 12, y: 12)
            .scaleEffect(isActive ? 1.08 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !gestureActive else { return }
                        gestureActive = true
                        viewModel.beginRecording()
                    }
                    .onEnded { _ in
                        if gestureActive {
                            viewModel.finishRecording()
                            gestureActive = false
                        }
                    }
            )
    }

    private var repositoryButton: some View {
        Button {
            showRepository = true
        } label: {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.primary)
                .padding(16)
                .background(
                    Capsule()
                        .fill(Color(.secondarySystemBackground))
                )
        }
        .accessibilityLabel("查看录音仓库")
    }
}
