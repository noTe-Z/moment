import SwiftUI
import SwiftData

struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = CaptureViewModel()
    @State private var didBindContext = false
    @State private var gestureActive = false
    @State private var showRepository = false
    @State private var dragOffset: CGSize = .zero
    @State private var lockProgress: CGFloat = 0
    @State private var isLocked = false
    @State private var showLockGuide = false

    private let lockActivationDistance: CGFloat = 150
    private let lockTargetYOffset: CGFloat = 190

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
            resetLockState(animated: false)
        }
        .onChange(of: viewModel.isRecording) { isRecording in
            if !isRecording {
                resetLockState(animated: true)
            }
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
        let buttonOffset = isLocked ? CGSize(width: 0, height: lockTargetYOffset) : dragOffset
        let currentLockProgress = isLocked ? CGFloat(1) : max(CGFloat(0), min(CGFloat(1), lockProgress))
        let progressValue = Double(currentLockProgress)
        let buttonRadius: CGFloat = 110 // 按钮半径（也是中心点到边缘的距离）

        return GeometryReader { geometry in
            ZStack {
                if showLockGuide || isLocked {
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [15, 20]))
                        .foregroundStyle(Color.accentColor.opacity(0.28 + 0.35 * progressValue))
                        .frame(width: 200, height: 200)
                        .background(
                            Circle()
                                .fill(Color.accentColor.opacity(0.14 * (isLocked ? 1 : progressValue)))
                                .blur(radius: 18)
                        )
                        .scaleEffect(CGFloat(0.9) + CGFloat(0.08) * currentLockProgress)
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height / 2 + lockTargetYOffset
                        )
                        .transition(.opacity.combined(with: .scale))
                        .animation(.easeInOut(duration: 0.2), value: showLockGuide)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isLocked)
                        .allowsHitTesting(false)
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(isActive ? 0.9 : 0.7),
                                Color.accentColor
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 220, height: 220)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(isActive ? 0.65 : 0.3), lineWidth: isLocked ? 8 : 6)
                            .blur(radius: 0.5)
                    )
                    .overlay(
                        Image(systemName: "lock.fill")
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(Color.white.opacity(isLocked ? 0.9 : 0))
                            .scaleEffect(isLocked ? 1 : 0.5)
                            .opacity(isLocked ? 1 : 0)
                            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isLocked)
                    )
                    .shadow(color: Color.accentColor.opacity(isActive ? 0.5 : 0.2), radius: isActive ? 24 : 12, y: isLocked ? 4 : 12)
                    .scaleEffect(isActive ? (isLocked ? CGFloat(1.05) : CGFloat(1.08)) : CGFloat(1.0))
                    .position(
                        x: geometry.size.width / 2 + buttonOffset.width,
                        y: geometry.size.height / 2 + buttonOffset.height
                    )
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: buttonOffset)
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // 手势坐标是相对于 Circle 的 frame (220x220)
                                // Circle 的中心点是 (110, 110)
                                let startLocation = value.startLocation
                                let distanceFromCenter = sqrt(
                                    pow(startLocation.x - buttonRadius, 2) +
                                    pow(startLocation.y - buttonRadius, 2)
                                )
                                
                                // 只有触摸点在按钮半径范围内才处理手势
                                guard distanceFromCenter <= buttonRadius else { return }
                                
                                handleDragChanged(value)
                            }
                            .onEnded { value in
                                // 只有之前手势是激活状态才处理结束
                                guard gestureActive else { return }
                                
                                handleDragEnded(value)
                            }
                    )
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded {
                                // 锁定状态下，点击按钮区域才能结束录音
                                guard isLocked, viewModel.isRecording else { return }
                                viewModel.finishRecording()
                                resetLockState(animated: true)
                            }
                    )
            }
        }
        .frame(width: 220, height: 220)
        .padding(.bottom, lockTargetYOffset)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
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

private extension CaptureView {
    func handleDragChanged(_ value: DragGesture.Value) {
        guard !isLocked else { return }

        if !gestureActive {
            gestureActive = true
            viewModel.beginRecording()
        }

        let verticalTranslation = max(value.translation.height, 0)
        let clampedVertical = min(verticalTranslation, lockTargetYOffset + 60)
        dragOffset = CGSize(width: 0, height: clampedVertical)

        let progress = min(1, clampedVertical / lockActivationDistance)
        lockProgress = progress
        showLockGuide = progress > 0.05
    }

    func handleDragEnded(_ value: DragGesture.Value) {
        guard gestureActive else { return }
        gestureActive = false

        guard viewModel.isRecording else {
            resetLockState(animated: true)
            return
        }

        let verticalTranslation = max(value.translation.height, 0)

        if verticalTranslation >= lockActivationDistance {
            lockRecording()
        } else {
            viewModel.finishRecording()
            resetLockState(animated: true)
        }
    }

    func lockRecording() {
        guard viewModel.isRecording else {
            resetLockState(animated: true)
            return
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            isLocked = true
            dragOffset = CGSize(width: 0, height: lockTargetYOffset)
            lockProgress = 1
            showLockGuide = true
        }
    }

    func resetLockState(animated: Bool) {
        let updates = {
            dragOffset = .zero
            lockProgress = 0
            showLockGuide = false
            isLocked = false
        }

        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                updates()
            }
        } else {
            updates()
        }

        gestureActive = false
    }
}
