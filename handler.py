# handler.py
# -*- coding: utf-8 -*-

import boto3
import os
import pickle
import face_recognition
import json
import traceback

# 初始化 AWS 服务客户端
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')

def handler(event, context):
    """
    当视频文件上传到 S3 输入 Bucket 时，此函数由 Lambda 触发。
    """
    print("事件触发，开始执行 Lambda 函数...")
    
    # 使用 try...finally 结构确保临时文件总能被清理
    try:
        # 1. 从 S3 事件中解析 Bucket 和文件名
        try:
            bucket_name = event['Records'][0]['s3']['bucket']['name']
            video_key = event['Records'][0]['s3']['object']['key']
            # 获取不带扩展名的文件名，例如 "Test_0"
            video_name_without_ext = os.path.splitext(video_key)[0]
            
            # 根据输入 bucket 动态生成输出 bucket 名称
            # 例如 'pj3-img-in' -> 'pj3-img-out'
            output_bucket_name = bucket_name.replace('input', 'output').replace('in', 'out')
            
            print(f"输入 Bucket: {bucket_name}, 输出 Bucket: {output_bucket_name}, 视频文件: {video_key}")

        except KeyError:
            print("错误: 无法从 S3 事件中解析 Bucket 或 Key。")
            traceback.print_exc()
            return {'statusCode': 400, 'body': '错误的 S3 事件格式'}

        # 定义临时文件路径
        # 替换路径中的斜杠，以防文件名包含目录
        safe_video_key = video_key.replace('/', '_')
        tmp_video_path = f"/tmp/{safe_video_key}"
        tmp_frame_dir = "/tmp/frames/"
        
        # 创建用于存放帧的临时目录
        if not os.path.exists(tmp_frame_dir):
            os.makedirs(tmp_frame_dir)

        # 2. 从 S3 下载视频文件到 /tmp 目录
        print(f"开始从 s3://{bucket_name}/{video_key} 下载视频...")
        s3_client.download_file(bucket_name, video_key, tmp_video_path)
        print("视频下载完成。")

        # 3. 使用 ffmpeg 从视频中提取帧 (每秒1帧)
        ffmpeg_command = f"ffmpeg -i {tmp_video_path} -r 1 {tmp_frame_dir}image-%3d.jpeg"
        print(f"正在运行 ffmpeg 命令: {ffmpeg_command}")
        os.system(ffmpeg_command)
        print("帧提取完成。")

        # 4. 加载已知的面部编码 (修正了文件路径)
        # 'encoding' 文件与 handler.py 在同一个目录 /var/task/
        print("正在加载已知的人脸编码文件 'encoding'...")
        with open('encoding', 'rb') as f:
            known_face_data = pickle.load(f)
        known_face_encodings = known_face_data['encodings']
        known_face_names = known_face_data['names']
        print(f"已成功加载 {len(known_face_names)} 个已知人脸编码。")

        # 5. 识别人脸 (找到第一个就停止)
        student_name = None
        frame_files = sorted(os.listdir(tmp_frame_dir))
        
        if not frame_files:
            print("警告: ffmpeg 未能提取任何帧。")
            return {'statusCode': 400, 'body': '无法处理视频，未提取到帧'}

        print(f"开始在 {len(frame_files)} 个帧中识别人脸...")
        for frame_file in frame_files:
            frame_path = os.path.join(tmp_frame_dir, frame_file)
            unknown_image = face_recognition.load_image_file(frame_path)
            face_locations = face_recognition.face_locations(unknown_image)
            
            if face_locations:
                unknown_encodings = face_recognition.face_encodings(unknown_image, face_locations)
                
                # 只处理该帧的第一个人脸编码
                matches = face_recognition.compare_faces(known_face_encodings, unknown_encodings[0], tolerance=0.55)
                
                if True in matches:
                    first_match_index = matches.index(True)
                    student_name = known_face_names[first_match_index]
                    print(f"识别成功！在帧 {frame_file} 中找到学生: {student_name}")
                    # 按照项目要求，找到第一个就停止所有循环
                    break 
            if student_name:
                break
        
        if not student_name:
            print("在所有帧中都未能识别出已知的学生。")
            return {'statusCode': 404, 'body': '未找到匹配的学生'}

        # 6. 在 DynamoDB 中查询学生信息
        print(f"正在 DynamoDB 的 'student_data' 表中查询 '{student_name}' 的信息...")
        student_table = dynamodb.Table('student_data')
        response = student_table.get_item(Key={'name': student_name})
        
        if 'Item' not in response:
            print(f"错误: 在 DynamoDB 中未找到学生 '{student_name}' 的记录。")
            return {'statusCode': 404, 'body': f"在数据库中未找到学生 {student_name}"}

        # 7. 格式化为 CSV 并上传到 S3 输出 Bucket
        item = response['Item']
        # 格式: 姓名,专业,年级, (注意末尾的逗号)
        result_data = f"{item['name']},{item['major']},{item['year']},"
        print(f"查询成功，格式化结果为: {result_data}")
        
        result_file_path = f"/tmp/{video_name_without_ext}"
        with open(result_file_path, 'w') as f:
            f.write(result_data)
        
        print(f"正在将结果文件上传到 s3://{output_bucket_name}/{video_name_without_ext}...")
        s3_client.upload_file(result_file_path, output_bucket_name, video_name_without_ext)
        print("上传成功。")
        
        print("处理流程圆满完成！")
        return {
            'statusCode': 200,
            'body': json.dumps(f'成功处理 {video_key}，结果已保存到 {output_bucket_name}')
        }

    except Exception as e:
        # 捕获任何异常并打印详细信息，方便调试
        print(f"!!! Lambda 执行过程中发生严重错误 !!!")
        traceback.print_exc()
        return {'statusCode': 500, 'body': json.dumps(f"服务器内部错误: {str(e)}")}

    finally:
        # 8. 清理 /tmp 目录下的所有临时文件
        print("开始清理临时文件...")
        if 'tmp_video_path' in locals() and os.path.exists(tmp_video_path):
            os.remove(tmp_video_path)
        if 'tmp_frame_dir' in locals() and os.path.exists(tmp_frame_dir):
            for f in os.listdir(tmp_frame_dir):
                os.remove(os.path.join(tmp_frame_dir, f))
            os.rmdir(tmp_frame_dir)
        if 'result_file_path' in locals() and os.path.exists(result_file_path):
            os.remove(result_file_path)
        print("清理完成。函数执行结束。")

