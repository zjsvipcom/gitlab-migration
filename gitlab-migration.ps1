# 读取配置文件
$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "配置文件不存在: $configPath"
    exit 1
}

try {
    $config = Get-Content $configPath | ConvertFrom-Json
} catch {
    Write-Error "配置文件格式错误: $_"
    exit 1
}

# 从配置文件读取设置
$OLD_GROUP = $config.old_gitlab.url
$OLD_GROUP_PATH = $config.old_gitlab.group_path
$NEW_GROUP = $config.new_gitlab.url
$NEW_GROUP_PATH = $config.new_gitlab.group_path

# 设置 GitLab API 访问令牌
$OLD_GITLAB_TOKEN = $config.old_gitlab.token
$NEW_GITLAB_TOKEN = $config.new_gitlab.token

$oldHeaders = @{
    "PRIVATE-TOKEN" = $OLD_GITLAB_TOKEN
    "Content-Type" = "application/json"
}

$newHeaders = @{
    "PRIVATE-TOKEN" = $NEW_GITLAB_TOKEN
    "Content-Type" = "application/json"
}

# 定义需要跳过的仓库列表
$skipRepos = $config.skip_repos

# 创建日志函数
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path "migration.log" -Value $logMessage
}

# 创建错误日志函数
function Write-ErrorLog {
    param(
        [string]$Message,
        [string]$ErrorDetails
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [ERROR] $Message`n详细信息: $ErrorDetails"
    Write-Host $logMessage -ForegroundColor Red
    Add-Content -Path "migration.log" -Value $logMessage
    Add-Content -Path "error.log" -Value $logMessage
}

# 验证 API 访问
function Test-GitLabAccess {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$ServerName
    )
    try {
        Write-Log "正在验证 $ServerName GitLab API 访问: $BaseUrl"
        $versionUrl = "$BaseUrl/api/v4/version"
        $versionInfo = Invoke-RestMethod -Uri $versionUrl -Headers $Headers -Method Get
        Write-Log "GitLab版本: $($versionInfo.version)"
        Write-Log "API版本: $($versionInfo.api_version)"
        return $true
    } catch {
        if ($_.Exception.Response.StatusCode -eq 401) {
            Write-ErrorLog "GitLab API 访问验证失败" "$ServerName 访问令牌无效或已过期，请检查令牌权限和有效期"
        } elseif ($_.Exception.Response.StatusCode -eq 403) {
            Write-ErrorLog "GitLab API 访问验证失败" "$ServerName 访问令牌权限不足，需要read_api和read_repository权限"
        } else {
            Write-ErrorLog "GitLab API 访问验证失败" $_.Exception.Message
        }
        return $false
    }
}

# 添加群组信息缓存
$script:groupInfoCache = @{}

# 获取群组信息
function Get-GroupInfo {
    param(
        [string]$BaseUrl,
        [string]$GroupPath,
        [hashtable]$Headers
    )
    try {
        # 检查缓存中是否已有该群组信息
        $cacheKey = "$BaseUrl/$GroupPath"
        if ($script:groupInfoCache.ContainsKey($cacheKey)) {
            Write-Log "从缓存获取群组信息: $GroupPath"
            return $script:groupInfoCache[$cacheKey]
        }

        Write-Log "正在获取群组信息: $GroupPath"
        
        # 首先尝试使用搜索API
        $searchUrl = "$BaseUrl/api/v4/groups?search=$($GroupPath.Split('/')[-1])&per_page=100"
        Write-Log "搜索群组: $searchUrl"
        
        try {
            $searchResponse = Invoke-RestMethod -Uri $searchUrl -Headers $Headers -Method Get
            Write-Log "搜索API返回 $($searchResponse.Count) 个结果"
            
            # 记录所有找到的群组
            foreach ($group in $searchResponse) {
                Write-Log "找到群组: $($group.full_path) (ID: $($group.id))"
                if ($group.full_path -eq $GroupPath) {
                    Write-Log "找到目标群组，ID: $($group.id)"
                    # 将群组信息存入缓存
                    $script:groupInfoCache[$cacheKey] = $group
                    return $group
                }
            }
        } catch {
            Write-Log "搜索API请求失败: $($_.Exception.Message)"
        }
        
        # 如果搜索失败，尝试直接获取
        $encodedPath = $GroupPath -replace "/", "%2F"
        $directUrl = "$BaseUrl/api/v4/groups/$encodedPath"
        Write-Log "尝试直接获取群组信息: $directUrl"
        
        try {
            $groupInfo = Invoke-RestMethod -Uri $directUrl -Headers $Headers -Method Get
            Write-Log "直接获取群组信息成功，ID: $($groupInfo.id)"
            # 将群组信息存入缓存
            $script:groupInfoCache[$cacheKey] = $groupInfo
            return $groupInfo
        } catch {
            Write-ErrorLog "获取群组信息失败" "群组: $GroupPath`n错误信息: $($_.Exception.Message)"
            throw "无法获取群组信息，停止执行"
        }
    } catch {
        Write-ErrorLog "获取群组信息失败" "群组: $GroupPath`n错误信息: $($_.Exception.Message)"
        throw "无法获取群组信息，停止执行"
    }
}

# 获取仓库列表
function Get-Repositories {
    param(
        [string]$BaseUrl,
        [string]$GroupPath,
        [hashtable]$Headers
    )
    try {
        Write-Log "正在获取群组 $GroupPath 下的仓库列表..."
        
        # 获取群组信息（使用缓存）
        $groupInfo = Get-GroupInfo -BaseUrl $BaseUrl -GroupPath $GroupPath -Headers $Headers
        Write-Log "群组ID: $($groupInfo.id)"
        
        # 使用群组ID获取项目列表
        $apiUrl = "$BaseUrl/api/v4/groups/$($groupInfo.id)/projects?per_page=100"
        Write-Log "API 请求地址: $apiUrl"
        
        try {
            $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Get
            Write-Log "API请求成功，返回 $($response.Count) 个项目"
            
            # 记录所有找到的项目
            $repos = @()
            foreach ($project in $response) {
                Write-Log "找到项目: $($project.path_with_namespace) (ID: $($project.id))"
                $repos += [PSCustomObject]@{
                    url = $project.http_url_to_repo
                    id = $project.id
                    path = $project.path_with_namespace
                    description = $project.description
                }
            }
            
            Write-Log "成功获取到 $($repos.Count) 个仓库"
            return $repos
        } catch {
            Write-ErrorLog "API请求失败" "状态码: $($_.Exception.Response.StatusCode.value__)`n响应内容: $($_.ErrorDetails.Message)"
            throw
        }
    } catch {
        Write-ErrorLog "获取仓库列表失败" "API 地址: $apiUrl`n错误信息: $($_.Exception.Message)"
        throw "无法获取仓库列表，停止执行"
    }
}

# 获取子群组列表
function Get-Subgroups {
    param(
        [string]$BaseUrl,
        [string]$GroupPath,
        [hashtable]$Headers
    )
    try {
        Write-Log "正在获取群组 $GroupPath 下的子群组列表..."
        
        # 获取群组信息（使用缓存）
        $groupInfo = Get-GroupInfo -BaseUrl $BaseUrl -GroupPath $GroupPath -Headers $Headers
        Write-Log "群组ID: $($groupInfo.id)"
        
        # 使用群组ID获取子群组列表
        $apiUrl = "$BaseUrl/api/v4/groups/$($groupInfo.id)/subgroups?per_page=100"
        Write-Log "API 请求地址: $apiUrl"
        
        try {
            $groups = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Get
            Write-Log "API请求成功，返回 $($groups.Count) 个子群组"
            
            # 记录所有找到的子群组并缓存
            foreach ($group in $groups) {
                Write-Log "找到子群组: $($group.full_path) (ID: $($group.id))"
                $cacheKey = "$BaseUrl/$($group.full_path)"
                $script:groupInfoCache[$cacheKey] = $group
            }
            
            return $groups
        } catch {
            Write-ErrorLog "API请求失败" "状态码: $($_.Exception.Response.StatusCode.value__)`n响应内容: $($_.ErrorDetails.Message)"
            throw
        }
    } catch {
        Write-ErrorLog "获取子群组列表失败" "API 地址: $apiUrl`n错误信息: $($_.Exception.Message)"
        throw "无法获取子群组列表，停止执行"
    }
}

# 验证群组存在性
function Test-GroupExists {
    param(
        [string]$BaseUrl,
        [string]$GroupPath,
        [hashtable]$Headers
    )
    try {
        Write-Log "检查群组是否存在: $GroupPath"
        $groupInfo = Get-GroupInfo -BaseUrl $BaseUrl -GroupPath $GroupPath -Headers $Headers
        Write-Log "群组存在: $GroupPath (ID: $($groupInfo.id))"
        return $true
    } catch {
        Write-ErrorLog "群组不存在或无法访问" "群组: $GroupPath`n错误信息: $($_.Exception.Message)"
        return $false
    }
}

# 初始化日志文件
Write-Log "开始迁移任务"
Write-Log "旧仓库地址: $OLD_GROUP/$OLD_GROUP_PATH"
Write-Log "新仓库地址: $NEW_GROUP/$NEW_GROUP_PATH"

# 验证旧 GitLab 访问
if (-not (Test-GitLabAccess -BaseUrl $OLD_GROUP -Headers $oldHeaders -ServerName "旧")) {
    Write-ErrorLog "无法访问旧 GitLab 服务器" "请检查网络连接和访问令牌"
    exit 1
}

# 验证新 GitLab 访问
if (-not (Test-GitLabAccess -BaseUrl $NEW_GROUP -Headers $newHeaders -ServerName "新")) {
    Write-ErrorLog "无法访问新 GitLab 服务器" "请检查网络连接和访问令牌"
    exit 1
}

# 获取所有仓库列表
$allRepos = @{}

try {
    # 首先获取根群组下的仓库
    Write-Log "获取根群组 $OLD_GROUP_PATH 下的仓库..."
    $rootRepos = Get-Repositories -BaseUrl $OLD_GROUP -GroupPath $OLD_GROUP_PATH -Headers $oldHeaders
    foreach ($repo in $rootRepos) {
        $allRepos[$repo.url] = $repo
    }
    Write-Log "根群组下找到 $($rootRepos.Count) 个仓库"

    # 获取并处理子群组
    Write-Log "获取子群组..."
    $subgroups = Get-Subgroups -BaseUrl $OLD_GROUP -GroupPath $OLD_GROUP_PATH -Headers $oldHeaders
    foreach ($subgroup in $subgroups) {
        $subgroupPath = $subgroup.full_path
        Write-Log "处理子群组: $subgroupPath"
        $subgroupRepos = Get-Repositories -BaseUrl $OLD_GROUP -GroupPath $subgroupPath -Headers $oldHeaders
        foreach ($repo in $subgroupRepos) {
            $allRepos[$repo.url] = $repo
        }
        Write-Log "子群组 $subgroupPath 下找到 $($subgroupRepos.Count) 个仓库"
    }
} catch {
    Write-ErrorLog "获取仓库列表过程中出错" $_.Exception.Message
    Write-Log "由于错误，停止执行脚本"
    exit 1
}

# 获取唯一的仓库列表
$uniqueRepos = $allRepos.Values
Write-Log "总共找到 $($uniqueRepos.Count) 个唯一仓库需要迁移"

# 将仓库列表写入文件
Write-Log "正在将仓库列表写入 repo-list.txt..."
$repoList = @()
foreach ($repo in $uniqueRepos) {
    $repoList += [PSCustomObject]@{
        Repository = $repo.url
        Status = "待迁移"
        LastUpdate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
}
$repoList | ConvertTo-Json | Out-File -FilePath "repo-list.txt" -Encoding utf8
Write-Log "仓库列表已保存到 repo-list.txt"

# 创建群组映射表
$groupMap = @{}

# 获取所有群组信息
$allGroups = @($OLD_GROUP_PATH)
$allGroups += $subgroups | ForEach-Object { $_.full_path }

foreach ($groupPath in $allGroups) {
    try {
        Write-Log "获取群组信息: $groupPath"
        # 使用Get-GroupInfo函数获取群组信息（会使用缓存）
        $groupInfo = Get-GroupInfo -BaseUrl $OLD_GROUP -GroupPath $groupPath -Headers $oldHeaders
        $groupMap[$groupPath] = @{
            id = $groupInfo.id
            description = $groupInfo.description
            name = $groupInfo.name
            path = $groupInfo.path
        }
    } catch {
        Write-ErrorLog "获取群组信息失败" "群组: $groupPath`n错误信息: $($_.Exception.Message)"
    }
}

# 循环处理每个仓库
$successCount = 0
$errorCount = 0

foreach ($repo in $uniqueRepos) {
    try {
        if (-not $repo.id) {
            Write-ErrorLog "仓库信息不完整" "仓库URL: $($repo.url)"
            throw "仓库信息不完整，停止执行"
        }

        # 检查是否需要跳过该仓库
        $repoName = Split-Path $repo.path -Leaf
        if ($skipRepos -contains $repoName) {
            Write-Log "跳过仓库迁移: $repoName"
            # 更新仓库状态为"已跳过"
            $repoList = Get-Content "repo-list.txt" | ConvertFrom-Json
            $repoItem = $repoList | Where-Object { $_.Repository -eq $repo.url }
            if ($repoItem) {
                $repoItem.Status = "已跳过"
                $repoItem.LastUpdate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                $repoList | ConvertTo-Json | Out-File -FilePath "repo-list.txt" -Encoding utf8
            }
            continue
        }

        # 使用项目ID获取仓库信息
        Write-Log "正在获取仓库信息，ID: $($repo.id)"
        $apiUrl = "$OLD_GROUP/api/v4/projects/$($repo.id)"
        Write-Log "API 请求地址: $apiUrl"
        
        try {
            $repoInfo = Invoke-RestMethod -Uri $apiUrl -Headers $oldHeaders -Method Get
            Write-Log "成功获取仓库信息，路径: $($repoInfo.path_with_namespace)"
        } catch {
            Write-ErrorLog "获取仓库信息失败" "仓库ID: $($repo.id)`n错误信息: $($_.Exception.Message)"
            throw "获取仓库信息失败，停止执行"
        }
        
        $REPO_PATH = $repo.path
        if (-not $REPO_PATH) {
            Write-ErrorLog "仓库路径为空" "仓库ID: $($repo.id)"
            throw "仓库路径为空，停止执行"
        }

        # 去掉BigData前缀
        $REPO_PATH = $REPO_PATH -replace "^BigData/", ""
        $NEW_REPO = "${NEW_GROUP}/${NEW_GROUP_PATH}/${REPO_PATH}.git"
        
        Write-Log "开始处理仓库: $REPO_PATH"
        
        # 更新仓库状态为"迁移中"
        $repoList = Get-Content "repo-list.txt" | ConvertFrom-Json
        $repoItem = $repoList | Where-Object { $_.Repository -eq $repo.url }
        if ($repoItem) {
            $repoItem.Status = "迁移中"
            $repoItem.LastUpdate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $repoList | ConvertTo-Json | Out-File -FilePath "repo-list.txt" -Encoding utf8
        }
        
        Write-Log "原始仓库URL: $($repo.url)"
        Write-Log "提取的仓库路径: $REPO_PATH"
        Write-Log "仓库描述: $($repo.description)"
        
        # 解析群组路径
        $groupPath = Split-Path $REPO_PATH -Parent
        if ($groupPath) {
            Write-Log "处理群组路径: $groupPath"
            # 确保使用正斜杠，并去掉重复的BigData
            $groupPath = $groupPath -replace "\\", "/" -replace "^BigData/", ""
            $newGroupPath = $NEW_GROUP_PATH + "/" + $groupPath
            
            # 获取父群组ID
            $parentGroupPath = $NEW_GROUP_PATH
            $parentGroupName = $parentGroupPath.Split('/')[-1]
            $apiUrl = "$NEW_GROUP/api/v4/groups?search=$parentGroupName&per_page=100"
            Write-Log "搜索父群组: $parentGroupName"
            Write-Log "API 请求地址: $apiUrl"
            
            $groups = Invoke-RestMethod -Uri $apiUrl -Headers $newHeaders -Method Get
            $parentGroup = $groups | Where-Object { $_.full_path -eq $parentGroupPath }
            
            if (-not $parentGroup) {
                Write-ErrorLog "未找到父群组" "群组: $parentGroupPath"
                throw "未找到父群组，停止执行"
            }
            Write-Log "父群组ID: $($parentGroup.id)"
            
            # 检查目标群组是否存在
            $groupName = Split-Path $groupPath -Leaf
            $apiUrl = "$NEW_GROUP/api/v4/groups?search=$groupName&per_page=100"
            Write-Log "搜索子群组: $groupName"
            Write-Log "API 请求地址: $apiUrl"
            
            $groups = Invoke-RestMethod -Uri $apiUrl -Headers $newHeaders -Method Get
            $existingGroup = $groups | Where-Object { $_.full_path -eq $newGroupPath }
            
            if (-not $existingGroup) {
                Write-Log "创建群组: $groupName"
                
                # 从缓存中获取原始群组信息
                $originalGroupPath = "BigData/" + $groupPath
                Write-Log "从缓存获取原始群组信息: $originalGroupPath"
                
                if ($groupMap.ContainsKey($originalGroupPath)) {
                    $originalGroup = $groupMap[$originalGroupPath]
                    Write-Log "从缓存获取到群组信息，名称: $($originalGroup.name), 描述: $($originalGroup.description)"
                    
                    $groupData = @{
                        name = $originalGroup.name
                        path = $originalGroup.path
                        description = $originalGroup.description
                        parent_id = $parentGroup.id
                    }
                } else {
                    Write-Log "缓存中未找到群组信息，使用当前路径信息"
                    $groupData = @{
                        name = $groupName
                        path = $groupName
                        description = ""
                        parent_id = $parentGroup.id
                    }
                }
                
                $apiUrl = "${NEW_GROUP}/api/v4/groups"
                Write-Log "API 请求地址: $apiUrl"
                Write-Log "创建群组数据: $($groupData | ConvertTo-Json)"
                
                try {
                    $newGroup = Invoke-RestMethod -Uri $apiUrl -Headers $newHeaders -Method Post -Body ($groupData | ConvertTo-Json) -ContentType "application/json"
                    Write-Log "群组创建成功，ID: $($newGroup.id), 名称: $($newGroup.name), 描述: $($newGroup.description)"
                } catch {
                    Write-ErrorLog "创建群组失败" "群组: $groupName`n错误信息: $($_.Exception.Message)"
                    throw "创建群组失败，停止执行"
                }
            } else {
                Write-Log "群组已存在: $groupName (ID: $($existingGroup.id))"
            }
        }

        # 检查目标仓库是否存在
        $newRepoPath = $NEW_GROUP_PATH + "/" + $REPO_PATH
        $repoName = Split-Path $REPO_PATH -Leaf
        $searchUrl = "${NEW_GROUP}/api/v4/projects?search=$repoName&per_page=100"
        Write-Log "检查仓库是否存在: $newRepoPath"
        Write-Log "搜索API地址: $searchUrl"

        try {
            $response = Invoke-RestMethod -Uri $searchUrl -Headers $newHeaders -Method Get -ErrorAction SilentlyContinue
            if ($response) {
                # 在搜索结果中查找完全匹配的仓库
                $existingRepo = $response | Where-Object { $_.path_with_namespace -eq $newRepoPath }
                if ($existingRepo) {
                    Write-Log "仓库已存在: $newRepoPath (ID: $($existingRepo.id))"
                    Write-Log "跳过仓库创建和推送步骤"
                    
                    # 更新仓库状态为"已迁移"
                    $repoList = Get-Content "repo-list.txt" | ConvertFrom-Json
                    $repoItem = $repoList | Where-Object { $_.Repository -eq $repo.url }
                    if ($repoItem) {
                        $repoItem.Status = "已迁移"
                        $repoItem.LastUpdate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                        $repoList | ConvertTo-Json | Out-File -FilePath "repo-list.txt" -Encoding utf8
                    }
                    
                    $successCount++
                    Write-Log "仓库已存在，跳过迁移: $REPO_PATH"
                    
                    # 设置项目描述
                    if ($repo.description) {
                        Write-Log "设置项目描述: $($repo.description)"
                        $updateData = @{
                            description = $repo.description
                        }
                        $apiUrl = "${NEW_GROUP}/api/v4/projects/$($existingRepo.id)"
                        Write-Log "API 请求地址: $apiUrl"
                        
                        try {
                            $response = Invoke-RestMethod -Uri $apiUrl -Headers $newHeaders -Method Put -Body ($updateData | ConvertTo-Json) -ContentType "application/json"
                            Write-Log "项目描述设置成功"
                        } catch {
                            Write-Log "设置项目描述失败"
                            Write-Log "API响应状态码: $($_.Exception.Response.StatusCode.value__)"
                            Write-Log "API响应内容: $($_.ErrorDetails.Message)"
                            Write-Log "继续执行，不影响迁移流程"
                        }
                    }
                    
                    continue
                } else {
                    Write-Log "未找到完全匹配的仓库，准备创建: $newRepoPath"
                }
            }
        } catch {
            Write-Log "搜索仓库失败，准备创建: $newRepoPath"
            Write-Log "API响应状态码: $($_.Exception.Response.StatusCode.value__)"
            Write-Log "API响应内容: $($_.ErrorDetails.Message)"
            Write-Log "完整错误信息: $($_.Exception.Message)"
        }

        # 创建临时目录
        $tempDir = Join-Path $PWD.Path "$REPO_PATH.git"
        Write-Log "创建临时目录: $tempDir"
        New-Item -ItemType Directory -Force -Path (Split-Path $tempDir -Parent) | Out-Null

        # 保存当前目录
        $currentDir = $PWD.Path

        # 克隆仓库
        Write-Log "开始克隆仓库: $($repo.url)"
        git clone --mirror $($repo.url) $tempDir
        if ($LASTEXITCODE -ne 0) {
            throw "克隆仓库失败，退出代码: $LASTEXITCODE"
        }
        Set-Location $tempDir

        # 推送仓库
        Write-Log "开始推送到新仓库: $NEW_REPO"
        # 使用--mirror选项，但排除合并请求引用
        git push --mirror $NEW_REPO --no-verify 2>$null
        if ($LASTEXITCODE -ne 0) {
            # 检查是否只是合并请求引用的错误
            $errorOutput = git push --mirror $NEW_REPO --no-verify 2>&1
            if ($errorOutput -match "remote rejected.*deny updating a hidden ref") {
                Write-Log "忽略合并请求引用的推送错误，继续执行"
            } else {
                throw "推送仓库失败，退出代码: $LASTEXITCODE"
            }
        }

        # 返回原目录
        Set-Location $currentDir

        # 验证仓库是否成功创建
        Write-Log "验证仓库是否成功创建..."
        $maxRetries = 3
        $retryCount = 0
        $repoCreated = $false

        while (-not $repoCreated -and $retryCount -lt $maxRetries) {
            try {
                if ($retryCount -gt 0) {
                    $waitTime = $retryCount * 5
                    Write-Log "等待 $waitTime 秒后重试验证..."
                    Start-Sleep -Seconds $waitTime
                }

                # 使用search API验证仓库是否存在
                $searchUrl = "${NEW_GROUP}/api/v4/projects?search=$repoName&per_page=100"
                Write-Log "验证仓库是否存在: $searchUrl"
                
                $searchResponse = Invoke-RestMethod -Uri $searchUrl -Headers $newHeaders -Method Get
                $targetRepo = $searchResponse | Where-Object { $_.path_with_namespace -eq $newRepoPath }
                
                if ($targetRepo) {
                    Write-Log "仓库验证成功，找到匹配的仓库: $($targetRepo.path_with_namespace)"
                    $repoCreated = $true
                    
                    # 设置项目描述
                    if ($repo.description) {
                        Write-Log "设置项目描述: $($repo.description)"
                        $updateData = @{
                            description = $repo.description
                        }
                        $apiUrl = "${NEW_GROUP}/api/v4/projects/$($targetRepo.id)"
                        Write-Log "API 请求地址: $apiUrl"
                        
                        try {
                            $response = Invoke-RestMethod -Uri $apiUrl -Headers $newHeaders -Method Put -Body ($updateData | ConvertTo-Json) -ContentType "application/json"
                            Write-Log "项目描述设置成功"
                        } catch {
                            Write-Log "设置项目描述失败"
                            Write-Log "API响应状态码: $($_.Exception.Response.StatusCode.value__)"
                            Write-Log "API响应内容: $($_.ErrorDetails.Message)"
                            Write-Log "继续执行，不影响迁移流程"
                        }
                    }
                } else {
                    throw "未找到匹配的仓库"
                }
            } catch {
                $retryCount++
                Write-Log "仓库验证失败 (尝试 $retryCount/$maxRetries)"
                Write-Log "API响应状态码: $($_.Exception.Response.StatusCode.value__)"
                Write-Log "API响应内容: $($_.ErrorDetails.Message)"
                
                if ($retryCount -eq $maxRetries) {
                    throw "仓库创建验证失败，请检查仓库是否成功创建"
                }
            }
        }

        # 清理临时文件
        Remove-Item -Recurse -Force $tempDir
        Write-Log "临时文件清理完成"

        # 更新仓库状态为"已迁移"
        $repoList = Get-Content "repo-list.txt" | ConvertFrom-Json
        $repoItem = $repoList | Where-Object { $_.Repository -eq $repo.url }
        if ($repoItem) {
            $repoItem.Status = "已迁移"
            $repoItem.LastUpdate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $repoList | ConvertTo-Json | Out-File -FilePath "repo-list.txt" -Encoding utf8
        }

        $successCount++
        Write-Log "仓库迁移成功: $REPO_PATH"
    } catch {
        $errorCount++
        # 更新仓库状态为"迁移失败"
        $repoList = Get-Content "repo-list.txt" | ConvertFrom-Json
        $repoItem = $repoList | Where-Object { $_.Repository -eq $repo.url }
        if ($repoItem) {
            $repoItem.Status = "迁移失败"
            $repoItem.LastUpdate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $repoList | ConvertTo-Json | Out-File -FilePath "repo-list.txt" -Encoding utf8
        }
        Write-ErrorLog "仓库迁移失败: $REPO_PATH" $_.Exception.Message
        Write-Log "由于错误，停止执行脚本"
        exit 1
    }
}

# 输出迁移统计信息
Write-Log "迁移任务完成"
Write-Log "成功迁移: $successCount 个仓库"
Write-Log "失败数量: $errorCount 个仓库"
if ($errorCount -gt 0) {
    Write-Log "请查看 error.log 了解详细错误信息"
} 