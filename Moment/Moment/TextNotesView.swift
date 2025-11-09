import SwiftUI
import SwiftData

struct TextNotesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TextNote.updatedAt, order: .reverse) private var textNotes: [TextNote]
    
    var body: some View {
        List {
            if textNotes.isEmpty {
                emptyState
            } else {
                ForEach(textNotes) { note in
                    NavigationLink {
                        TextEditorView(
                            recording: associatedRecording(for: note),
                            existingNote: note
                        )
                    } label: {
                        TextNoteRow(note: note)
                    }
                }
                .onDelete(perform: deleteNotes)
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("暂时没有结构化表达")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("点击录音旁的编辑按钮，记录你的深度思考。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
    }
    
    private func deleteNotes(at offsets: IndexSet) {
        for index in offsets {
            let note = textNotes[index]
            modelContext.delete(note)
        }
        try? modelContext.save()
    }
    
    private func associatedRecording(for note: TextNote) -> Recording? {
        guard let recordingID = note.recordingID else { return nil }
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == recordingID })
        return try? modelContext.fetch(descriptor).first
    }
}

private struct TextNoteRow: View {
    let note: TextNote
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.title.isEmpty ? "无标题" : note.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            if !note.content.isEmpty {
                Text(note.content)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            Text(TimestampFormatter.display(for: note.updatedAt))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

