# 自包含镜像:Ubuntu 20.04 + 运行时依赖 + 刚交叉编译的 Linux 二进制
FROM --platform=linux/amd64 ubuntu:20.04

RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libssl1.1 libatomic1 \
 && rm -rf /var/lib/apt/lists/*

# 二进制来自 build/linux-x64_64(构建上下文设为该目录)
COPY keydb-server /usr/local/bin/keydb-server
COPY keydb-cli    /usr/local/bin/keydb-cli

EXPOSE 6379
ENTRYPOINT ["keydb-server"]
