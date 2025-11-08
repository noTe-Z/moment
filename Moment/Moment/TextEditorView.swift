import SwiftUI
import SwiftData

struct TextEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    let recording: Recording?
    let existingNote: TextNote?
    
    @State private var title: String
    @State private var content: String
    @State private var dragOffset: CGFloat = 0
    
    // 用于跟踪是否是新创建的笔记
    private let isNewNote: Bool
    
    init(recording: Recording? = nil, existingNote: TextNote? = nil) {
        self.recording = recording
        self.existingNote = existingNote
        self.isNewNote = existingNote == nil
        
        // 初始化状态
        _title = State(initialValue: existingNote?.title ?? "")
        _content = State(initialValue: existingNote?.content ?? "")
    }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 标题输入区
                TextField("标题", text: $title)
                    .font(.title2.bold())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color(UIColor.systemBackground))
                
                Divider()
                
                // 内容输入区
                TextEditor(text: $content)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .scrollContentBackground(.hidden)
                    .background(Color(UIColor.systemBackground))
            }
            .offset(x: dragOffset)
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    saveAndDismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                }
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    // 只允许从左向右拖动
                    if value.translation.width > 0 {
                        dragOffset = value.translation.width
                    }
                }
                .onEnded { value in
                    // 如果拖动超过屏幕宽度的 1/3，就关闭
                    if value.translation.width > UIScreen.main.bounds.width / 3 {
                        saveAndDismiss()
                    } else {
                        // 否则弹回
                        withAnimation(.spring(response: 0.3)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }
    
    private func saveAndDismiss() {
        // 只有在标题或内容不为空时才保存
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            
            if let existingNote = existingNote {
                // 更新现有笔记
                existingNote.title = title
                existingNote.content = content
                existingNote.updatedAt = Date()
            } else {
                // 创建新笔记
                let newNote = TextNote(
                    title: title.isEmpty ? "无标题" : title,
                    content: content,
                    recordingID: recording?.id
                )
                modelContext.insert(newNote)
            }
            
            try? modelContext.save()
        }
        
        dismiss()
    }
}

