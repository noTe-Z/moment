# AssemblyAI API Key 设置说明

## 重要提示

为了安全起见，API Key 不会提交到 Git 仓库中。每个开发者需要在自己的本地环境中配置。

## 设置方法

### 方法 1：在 Xcode Scheme 中设置（推荐）

1. 在 Xcode 中打开项目
2. 点击顶部 Scheme 选择器（项目名称旁边）
3. 选择 "Edit Scheme..."
4. 在左侧选择 "Run"
5. 切换到 "Arguments" 标签
6. 在 "Environment Variables" 部分，点击 "+" 按钮
7. 添加以下环境变量：
   - **Name**: `ASSEMBLYAI_API_KEY`
   - **Value**: 你的 AssemblyAI API Key
   - **Enabled**: ✓ (勾选)

### 方法 2：使用用户特定的 Scheme 文件

如果你已经有用户特定的 scheme 文件（位于 `xcuserdata/[你的用户名].xcuserdatad/xcschemes/`），可以直接编辑该文件添加环境变量。

## 获取 API Key

1. 访问 [AssemblyAI Dashboard](https://www.assemblyai.com/app)
2. 登录或注册账号
3. 在 Dashboard 中找到你的 API Key
4. 复制 API Key 并按照上述方法配置

## 验证配置

运行应用并尝试使用"语音转文字"功能。如果配置正确，功能应该可以正常工作。如果出现"缺少 AssemblyAI API Key"的错误，请检查环境变量是否正确设置。

## 安全提醒

- ⚠️ **永远不要**将 API Key 提交到 Git 仓库
- ⚠️ **永远不要**在代码中硬编码 API Key
- ✅ 使用环境变量或用户特定的配置文件
- ✅ 定期轮换 API Key（如果怀疑泄露）

