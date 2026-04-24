# vLLM Dashboard Demo 完整指南

## 1. 这个项目有 Dashboard 吗？

有的，vLLM 项目中有两类 **Dashboard**：

### 1.1 监控 Dashboard（可观测性）
位于 `examples/observability/dashboards/`，提供了与外部监控平台集成的面板配置：

- **Grafana** (`grafana/*.json`) — 支持导入到任何 Grafana 实例
- **Perses** (`perses/*.yaml`) — 支持 Dashboard-as-Code 工作流

包含两种面板：
- **Performance Statistics** — 跟踪延迟、吞吐量等性能指标
- **Query Statistics** — 监控请求量、查询性能等

需要配合 **Prometheus** 作为数据源使用。

### 1.2 性能基准测试 Dashboard
项目有一个公开的在线性能面板：
- **[vLLM Performance Dashboard](https://hud.pytorch.org/benchmark/llms?repoName=vllm-project%2Fvllm)**

这个面板会自动在每次 PR 合并或带 `perf-benchmarks` + `ready` 标签的 commit 时触发基准测试，用于追踪代码变更对性能的影响。

**总结**：vLLM 本身**没有内置的 Web 管理界面**，但提供了与 Grafana/Perses 集成的监控面板配置，以及一个公开的持续性能基准测试面板。

---

## 2. Perses 是什么？

**Perses** 是一个开源的云原生监控 Dashboard 平台，可以看作是 **Grafana 的现代替代品**。

### 核心特点

| 特性 | 说明 |
|------|------|
| **声明式配置** | Dashboard 用 **YAML** 定义（而非 Grafana 的 JSON），更适合版本控制和代码审查 |
| **GitOps 友好** | 原生支持 `Dashboard-as-Code`，可以直接用 Git 管理面板 |
| **Kubernetes 原生** | 提供 Perses Operator，支持通过 CRD 在 K8s 中管理面板 |
| **CLI 工具** | 提供 `percli` 命令行工具，支持 `percli apply -f dashboard.yaml` 的方式部署面板 |

### 与 Grafana 的区别

- **Grafana**：图形化 UI 编辑为主，导出 JSON，适合手动操作
- **Perses**：代码优先，YAML 配置为主，更适合自动化、基础设施即代码（IaC）场景

### 在 vLLM 中的使用

```bash
# 用 Perses CLI 导入
percli apply -f perses/performance_statistics.yaml
```

如果你团队已经在用 GitOps 管理基础设施，或者希望把监控面板和代码一起版本控制，Perses 是一个比 Grafana 更现代的选择。

---

## 3. 跑一个 Demo 让 Dashboard 有数据

核心思路：**启动 vLLM 服务 → 启动 Prometheus + Grafana → 发送请求产生 metrics → Dashboard 展示**。

### 3.1 需要 GPU 吗？

**不是必须的，但强烈推荐：**

| 环境 | 说明 |
|------|------|
| **有 GPU** | vLLM 为 GPU 优化，7B 模型在单卡上跑得很顺畅 |
| **无 GPU** | vLLM 支持 CPU 推理，但只能跑**很小的模型**（如 1B 以下），速度极慢，仅适合验证 Demo |

---

### 3.2 完整 Demo 步骤

#### 步骤 1：启动 vLLM 服务

vLLM 的 OpenAI-compatible server **默认开启** Prometheus metrics（在 `http://localhost:8000/metrics`）。

**有 GPU（推荐）：**
```bash
vllm serve mistralai/Mistral-7B-v0.1 --max-model-len 2048
```

**无 GPU（用小模型做验证）：**
```bash
# 启动一个 0.5B 的小模型
vllm serve Qwen/Qwen2.5-0.5B-Instruct --max-model-len 2048
```

> ⚠️ **注意**：第一次启动会自动从 HuggingFace 下载模型，需要能访问外网或配置镜像。

#### 步骤 2：启动 Prometheus + Grafana

进入项目自带的示例目录：

```bash
cd examples/observability/prometheus_grafana
docker compose up
```

这会启动：
- **Prometheus** → `http://localhost:9090`
- **Grafana** → `http://localhost:3000`（账号密码默认 `admin/admin`）

`prometheus.yaml` 已经配置好了每 5 秒从 `host.docker.internal:8000` 抓取 vLLM 的 metrics。

#### 步骤 3：发送请求产生数据

metrics 端点默认有基础数据，但想要 Dashboard 图表丰富，需要实际发送请求：

```bash
# 方式1：用 vllm 自带的 benchmark 工具产生负载
wget https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json

vllm bench serve \
    --model mistralai/Mistral-7B-v0.1 \
    --dataset-name sharegpt \
    --dataset-path ShareGPT_V3_unfiltered_cleaned_split.json \
    --request-rate 3.0

# 方式2：简单发几个请求验证
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistralai/Mistral-7B-v0.1",
    "prompt": "Hello, world!",
    "max_tokens": 50
  }'
```

#### 步骤 4：配置 Grafana 面板

1. 打开 `http://localhost:3000`，登录 `admin/admin`
2. **添加数据源**：`Connections → Data Sources → Add → Prometheus`
   - URL 填 `http://prometheus:9090`
   - Save & Test
3. **导入 Dashboard**：`Dashboards → Import → Upload JSON`
   - 上传 `examples/observability/dashboards/grafana/performance_statistics.json`
   - 再上传 `examples/observability/dashboards/grafana/query_statistics.json`
   - 数据源选择刚才添加的 `prometheus`

然后你就能看到延迟、吞吐量、请求量等实时图表了。

#### 验证数据

在配置完成前，可以先确认 raw metrics 是否正常：

```bash
curl http://localhost:8000/metrics | head
```

如果有输出（如 `vllm:gpu_cache_usage_perc` 等指标），说明数据链路正常，Dashboard 很快就会有图。

---

## 4. 安装 vLLM 的命令解析

### 4.1 这条命令的作用

```bash
VLLM_USE_PRECOMPILED=1 uv pip install -e . --torch-backend=cpu
```

| 部分 | 作用 |
|------|------|
| `VLLM_USE_PRECOMPILED=1` | **使用预编译 wheel**，跳过从源码编译 C++/CUDA 扩展（否则编译可能要几十分钟） |
| `uv pip install` | 用 `uv`（一个快速的 Python 包管理器）替代 `pip` 来安装 |
| `-e .` | **Editable 模式**安装当前目录里的项目，修改代码后无需重新安装 |
| `--torch-backend=cpu` | 安装 PyTorch 的 **CPU 版本**（不装 CUDA 相关依赖） |

### 4.2 你根本不需要 clone 这个项目！

如果你想**只是跑个 Demo 看 Dashboard**，最简化的流程是：

**直接安装 vLLM（不需要项目源码）：**
```bash
# 有 GPU
pip install vllm

# 无 GPU（纯 CPU）
pip install vllm --extra-index-url https://download.pytorch.org/whl/cpu
```

**复制项目里的 Dashboard 配置文件（只需这 3 个文件）：**
- `examples/observability/prometheus_grafana/docker-compose.yaml`
- `examples/observability/prometheus_grafana/prometheus.yaml`
- `examples/observability/dashboards/grafana/*.json`

**启动服务 + Docker Compose 即可**

### 4.3 什么情况下才需要用 `-e .`

只有当你要**修改 vLLM 源代码**并实时看到效果时，才需要：
1. `git clone` 这个项目
2. 在项目目录里执行 `pip install -e .`

如果只是跑 Demo、验证 Dashboard，**完全不需要下载整个仓库**。直接从 PyPI 装 `vllm` 包即可。

---

## 5. 在 Ubuntu 22.04.5 LTS 上安装 uv

### 5.1 推荐方式（不依赖 pip）

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

安装完成后，**重新加载 shell 配置**（或新开一个终端）：

```bash
source $HOME/.local/bin/env
```

验证：

```bash
uv --version
```

### 5.2 如果系统没有 pip

你可以直接用 `python3` 来装：

```bash
apt update && apt install -y python3-pip
pip3 install uv
```

或者跳过 `uv`，直接用系统自带的 `python3 -m pip`：

```bash
apt update && apt install -y python3-pip
python3 -m pip install vllm
```

`uv` 只是更快更方便，不是必须的。如果环境受限，用系统 `pip3` 完全没问题。

---

## 6. 纯 CPU 方式能在 Windows 里运行吗？

**Windows 原生不能直接跑 vLLM 的 CPU 版本**，但可以通过 **WSL2**（Windows Subsystem for Linux）来跑。

### 原因

vLLM 的 CPU 后端依赖：
- **oneDNN / OpenVINO**（Intel 优化库）
- **PyTorch CPU 版本**
- 各种 C++ 内核扩展

这些在 **Linux 上才能正常编译和运行**。Windows 原生环境下，vLLM 的底层 C++/CUDA 扩展编译会失败，官方也不提供 Windows 的预编译包。

### 推荐方案：WSL2 + Ubuntu

1. **在 WSL2 里装一个 Ubuntu（如果还没有）：**
   ```powershell
   wsl --install -d Ubuntu-22.04
   ```

2. **进入 WSL2 后，按 Linux 流程走：**
   ```bash
   # 安装 uv
   curl -LsSf https://astral.sh/uv/install.sh | sh
   source $HOME/.local/bin/env

   # 安装 vLLM CPU 版本
   pip install vllm
   ```

3. **启动服务：**
   ```bash
   vllm serve Qwen/Qwen2.5-0.5B-Instruct
   ```

### 如果一定要在 Windows 原生环境跑

唯一可行的替代方案是用 **Docker Desktop（WSL2 后端）**：

```powershell
docker run --rm -it -p 8000:8000 vllm/vllm-cpu-env:latest `
  python -m vllm.entrypoints.openai.api_server `
  --model Qwen/Qwen2.5-0.5B-Instruct
```

> 但这也依赖于 Docker 的 WSL2 后端，本质上还是在 Linux 容器里跑。

### 总结

| 方式 | 是否可行 |
|------|---------|
| Windows 原生直接装 | ❌ 不行 |
| WSL2 (Ubuntu) | ✅ 推荐 |
| Docker Desktop | ✅ 可行（底层也是 WSL2） |
