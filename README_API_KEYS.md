# API Keys 配置说明

## ⚠️ 安全提醒

本项目需要配置 API keys 才能使用 AI 功能。**请勿将 API keys 提交到 Git 仓库！**

## 配置方法

### 方式一：在 Xcode Scheme 中配置（推荐）

1. 在 Xcode 中打开项目
2. 点击顶部工具栏的 Scheme 选择器（Moment 旁边）
3. 选择 "Edit Scheme..."
4. 在左侧选择 "Run"
5. 切换到 "Arguments" 标签
6. 在 "Environment Variables" 部分添加：
   - `ASSEMBLYAI_API_KEY`: 你的 AssemblyAI API key
   - `OPENAI_API_KEY`: 你的 OpenAI API key

### 方式二：使用 xcconfig 文件（推荐用于团队开发）

1. 创建 `Moment/Config/Secrets.xcconfig` 文件（已在 .gitignore 中）
2. 添加以下内容：
   ```
   ASSEMBLYAI_API_KEY = your_assemblyai_key_here
   OPENAI_API_KEY = your_openai_key_here
   ```

## 获取 API Keys

### AssemblyAI
1. 访问 https://www.assemblyai.com/
2. 注册账号并登录
3. 在 Dashboard 中获取 API key

### OpenAI
1. 访问 https://platform.openai.com/
2. 注册账号并登录
3. 在 API keys 页面创建新的 API key

## 可选配置

### AssemblyAI 高级配置

- `ASSEMBLYAI_SPEECH_MODEL`: 指定语音模型（如 `universal-2` 支持多语言）
- `ASSEMBLYAI_LANGUAGE_CODE`: 强制指定语言（如 `zh` 或 `en`）
- `ASSEMBLYAI_WORD_BOOST`: 逗号分隔的词汇列表，提高识别准确度
- `ASSEMBLYAI_WORD_BOOST_STRENGTH`: 词汇增强强度（`low`/`medium`/`high`，默认 `high`）
- `ASSEMBLYAI_PUNCTUATE`: 是否添加标点符号（`true`/`false`，默认 `true`）

### OpenAI 高级配置

- `OPENAI_REWRITE_TEMPERATURE`: 生成温度（0.0-2.0，留空使用默认值 1.0）

## 安全最佳实践

1. **永远不要**将 API keys 硬编码在代码中
2. **永远不要**将包含 API keys 的文件提交到 Git
3. 定期轮换你的 API keys
4. 为不同的项目使用不同的 API keys
5. 如果不小心泄露了 API key，立即撤销并重新生成

## 如果不小心提交了 API Keys

如果你已经将 API keys 提交到了 Git 仓库：

1. **立即撤销并重新生成所有泄露的 API keys**
2. 使用 `git filter-branch` 或 BFG Repo-Cleaner 清理 Git 历史
3. Force push 到远程仓库（如果已经推送）
4. 通知所有协作者重新 clone 仓库

