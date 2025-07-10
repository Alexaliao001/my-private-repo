#!/bin/bash
# 这是一个“一键式”脚本，用于自动创建EC2实例、设置环境、构建Docker镜像，并在完成后自动清理所有资源。

# 如果任何命令失败，立即退出
set -e

# --- 用户配置 (已为你添加) ---
GITHUB_REPO_URL="https://github.com/Alexaliao001/my-private-repo"
# --- 结束配置 ---

# --- 静态配置 (请勿修改) ---
ECR_REPO_URI="068325470876.dkr.ecr.ap-northeast-2.amazonaws.com/project3-face-recognition:latest"
KEY_NAME="project3-builder-key-$(date +%s)"
SG_NAME="project3-builder-sg-$(date +%s)"
ROLE_NAME="project3-builder-role-$(date +%s)"
PROFILE_NAME="project3-builder-profile-$(date +%s)"
REGION="ap-northeast-2"
AMI_ID=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 --region ${REGION} --query 'Parameters[0].[Value]' --output text)
INSTANCE_TYPE="t2.micro"

# 定义一个清理函数
cleanup() {
    echo "--- 正在清理所有临时创建的 AWS 资源... ---"
    if [ ! -z "$INSTANCE_ID" ] && aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --output text &>/dev/null; then
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
        echo "⏳ 等待实例终止..."
        aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
        echo "✅ 实例已终止。"
    else
        echo "ℹ️ 实例已不存在或从未成功创建。"
    fi
    [ ! -z "$KEY_NAME" ] && aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION" &>/dev/null && echo "✅ 密钥对已删除。"
    [ ! -z "$SG_ID" ] && aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" &>/dev/null && echo "✅ 安全组已删除。"
    [ ! -z "$PROFILE_NAME" ] && [ ! -z "$ROLE_NAME" ] && aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" --region "$REGION" &>/dev/null
    [ ! -z "$PROFILE_NAME" ] && aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" --region "$REGION" &>/dev/null && echo "✅ 实例配置文件已删除。"
    [ ! -z "$ROLE_NAME" ] && aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess --region "$REGION" &>/dev/null
    [ ! -z "$ROLE_NAME" ] && aws iam delete-role --role-name "$ROLE_NAME" --region "$REGION" &>/dev/null && echo "✅ IAM 角色已删除。"
    rm -f "${KEY_NAME}.pem" trust-policy.json &>/dev/null && echo "✅ 本地临时文件已删除。"
    echo "🎉 清理完成！"
}
trap cleanup EXIT

# --- 主脚本开始 ---
echo "--- 步骤 1: 为EC2创建IAM角色 ---"
cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [ { "Effect": "Allow", "Principal": { "Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole" } ]
}
EOF
aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://trust-policy.json --region "$REGION" > /dev/null
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess --region "$REGION"
aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" --region "$REGION" > /dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" --region "$REGION"
echo "✅ IAM 角色和实例配置文件已创建。"
echo "⏳ 等待IAM角色生效 (15秒)..."
sleep 15

echo "--- 步骤 2: 创建密钥对和安全组 ---"
aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
chmod 400 "${KEY_NAME}.pem"
MY_IP=$(curl -s http://checkip.amazonaws.com)
SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Allow SSH for project builder" --query 'GroupId' --output text --region "$REGION")
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "${MY_IP}/32" --region "$REGION"
echo "✅ 密钥对和安全组已创建。"

echo "--- 步骤 3: 启动EC2实例 ---"
INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --iam-instance-profile Name="$PROFILE_NAME" --query 'Instances[0].InstanceId' --output text --region "$REGION")
echo "⏳ 实例 '$INSTANCE_ID' 正在启动，等待其进入运行状态..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$REGION")
echo "✅ 实例正在运行，公网IP为: $PUBLIC_IP"

echo "--- 步骤 4: 等待SSH服务就绪 (最多重试2分钟) ---"
RETRY_COUNT=0
MAX_RETRIES=12
RETRY_DELAY=10
until ssh -q -o "StrictHostKeyChecking no" -o "ConnectTimeout=10" -i "${KEY_NAME}.pem" ec2-user@"$PUBLIC_IP" "exit"; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "❌ SSH 连接失败，已达到最大重试次数。"
        exit 1
    fi
    echo "SSH服务尚未就绪，将在 ${RETRY_DELAY} 秒后重试... (尝试次数: ${RETRY_COUNT}/${MAX_RETRIES})"
    sleep $RETRY_DELAY
done
echo "✅ SSH服务已就绪！"

echo "--- 步骤 5: 在EC2上远程执行构建任务 ---"
# 定义要在远程服务器上执行的命令
REMOTE_SCRIPT="
    set -e
    echo '--- (云端) 正在安装 Docker & Git... ---'
    sudo yum update -y
    sudo yum install -y git
    sudo amazon-linux-extras install docker -y
    sudo service docker start
    sudo usermod -a -G docker ec2-user

    # 【关键修复】创建并启用 2GB 的交换空间 (虚拟内存)
    echo '--- (云端) 正在创建虚拟内存以进行编译... ---'
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile

    echo '--- (云端) 正在克隆你的 GitHub 仓库... ---'
    git clone ${GITHUB_REPO_URL}
    REPO_DIR=\$(basename ${GITHUB_REPO_URL} .git)
    cd \$REPO_DIR

    echo '--- (云端) 正在配置 AWS CLI... ---'
    aws configure set default.region ${REGION}

    echo '--- (云端) 正在构建并推送 Docker 镜像... 这会花费很长时间 (10-20分钟)，请耐心等待。 ---'
    # 使用 sudo 运行 docker
    sudo docker buildx build --platform linux/amd64 -t ${ECR_REPO_URI} . --push --provenance=false

    echo '--- (云端) ✅✅✅ 构建和推送已成功完成! ✅✅✅ ---'
"
# 通过 SSH 连接到远程服务器并执行脚本
ssh -o "StrictHostKeyChecking no" -i "${KEY_NAME}.pem" ec2-user@"$PUBLIC_IP" "$REMOTE_SCRIPT"

echo "🎉🎉🎉 恭喜！一键构建脚本已成功执行！你的镜像现在已经准备就绪，可以部署到 Lambda 了。 🎉🎉🎉"
# 脚本执行到这里会自动退出，并触发 cleanup 函数来清理所有资源
