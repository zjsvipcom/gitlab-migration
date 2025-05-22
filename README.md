# GitLab 仓库迁移工具

这个工具用于将 GitLab 仓库从一个实例迁移到另一个实例，保持仓库结构和描述信息。

## 功能特点

- 自动迁移仓库及其所有分支和标签
- 保持仓库描述信息
- 自动创建必要的群组结构
- 支持跳过特定仓库
- 详细的日志记录
- 迁移状态跟踪

## 快速开始

1. 克隆仓库：
   ```bash
   git clone https://github.com/zjsvipcom/gitlab-migration.git
   cd gitlab-migration
   ```

2. 复制示例配置文件：
   ```bash
   cp config.example.json config.json
   ```

3. 编辑 `config.json` 文件，填入您的 GitLab 配置信息

4. 运行迁移脚本：
   ```powershell
   .\gitlab-migration.ps1
   ```

## 配置说明

在 `config.json` 文件中配置以下信息：

```json
{
    "old_gitlab": {
        "url": "旧 GitLab 服务器地址",
        "group_path": "源群组路径",
        "token": "访问令牌"
    },
    "new_gitlab": {
        "url": "新 GitLab 服务器地址",
        "group_path": "目标群组路径",
        "token": "访问令牌"
    },
    "skip_repos": [
        "要跳过的仓库名称列表"
    ]
}
```

### 配置项说明

- `old_gitlab.url`: 旧 GitLab 服务器的完整 URL
- `old_gitlab.group_path`: 源群组的路径
- `old_gitlab.token`: 旧 GitLab 的访问令牌（需要 read_api 和 read_repository 权限）
- `new_gitlab.url`: 新 GitLab 服务器的完整 URL
- `new_gitlab.group_path`: 目标群组的路径
- `new_gitlab.token`: 新 GitLab 的访问令牌（需要 api 权限）
- `skip_repos`: 不需要迁移的仓库名称列表

## 使用方法

1. 确保已安装 PowerShell 5.1 或更高版本
2. 配置 `config.json` 文件
3. 运行迁移脚本：
   ```powershell
   .\gitlab-migration.ps1
   ```

## 日志文件

脚本会生成以下日志文件：

- `migration.log`: 详细的迁移过程日志
- `error.log`: 错误信息日志
- `repo-list.txt`: 仓库迁移状态列表

## 注意事项

1. 确保有足够的磁盘空间用于临时克隆仓库
2. 确保网络连接稳定
3. 建议在迁移前备份重要数据
4. 访问令牌需要有足够的权限

## 错误处理

如果迁移过程中出现错误：
1. 检查 `error.log` 文件了解详细错误信息
2. 确保配置文件中的信息正确
3. 验证访问令牌是否有效
4. 检查网络连接是否正常

## 贡献指南

1. Fork 本仓库
2. 创建您的特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交您的更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启一个 Pull Request

## 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情

## 联系方式

如有问题或建议，请提交 Issue 或 Pull Request。 
