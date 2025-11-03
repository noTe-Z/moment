# Moment iOS MVP

一个用于快速捕捉“微表达”语音片段的极简 iOS App。打开即录，松手即存，所有录音完全保存在本地。

## 功能概览
- **录音页**：按住中心按钮立即开始录音，松开后自动保存，配合震动与状态文字反馈。
- **仓库页**：按周分组倒序展示录音，点击即可播放 / 暂停。
- **本地存储**：音频文件存放在 App Documents/Recordings 目录，并通过 SwiftData 持久化元数据。

## 开始使用
1. 打开 `Moment/Moment.xcodeproj`。
2. 选择 iOS 17+ 模拟器或真机并运行。
3. 首次启动会弹出麦克风权限请求，允许后即可长按录音按钮开始记录。

## 结构说明
```
Moment/
├─ Moment.xcodeproj       # Xcode 工程
└─ Moment/                # App 源码与资源
   ├─ MomentApp.swift
   ├─ CaptureView.swift
   ├─ CaptureViewModel.swift
   ├─ RepositoryView.swift
   ├─ PlaybackManager.swift
   ├─ Recording.swift
   ├─ RecordingStore.swift
   ├─ Formatters.swift
   ├─ Info.plist
   └─ Assets.xcassets/
```

## 测试建议
- 在录音页长按开始录音，确认震动反馈、计时器显示与“已保存”提示。
- 进入仓库页，确认分组标题（本周/上周/月份周次）以及录音条目按时间倒序排列。
- 点击列表项，验证播放/暂停与状态高亮。
