# 最终、最稳健的 Dockerfile (全新策略)
# 我们使用一个标准的 Python 官方镜像，而不是有问题的 AWS 基础镜像
FROM python:3.8-slim-bullseye

# 设置工作目录
WORKDIR /var/task

# 步骤 1: 使用现代的 apt-get 安装系统依赖
# 这能确保我们获得足够新的 cmake (>=3.10) 和 ffmpeg
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    ffmpeg && \
    rm -rf /var/lib/apt/lists/*

# 步骤 2: 安装 Python 库
# awslambdaric 是 AWS 官方的运行时接口，用于将我们的容器与 Lambda 连接
# 这次 pip install face_recognition 会成功，因为它能找到新版的 cmake
RUN pip install --no-cache-dir \
    awslambdaric \
    face_recognition

# 步骤 3: 复制我们的应用代码
COPY handler.py .
COPY encoding .

# 步骤 4: 设置 Lambda 的入口点
# 这是自定义运行时的标准做法
ENTRYPOINT [ "/usr/local/bin/python", "-m", "awslambdaric" ]

# 步骤 5: 将我们的 handler 函数作为命令传递给运行时
CMD [ "handler.handler" ]
