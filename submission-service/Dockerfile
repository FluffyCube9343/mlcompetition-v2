# Submission endpoint container; deployed on ECS Fargate by deploy-web.sh.
# Its task role needs ONLY lambda:InvokeFunction on the grader - see README.
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY index.html .

# port 80: the task's security group opens plain http on 80, no ALB in front
EXPOSE 80
CMD ["gunicorn", "--bind", "0.0.0.0:80", "--timeout", "900", "app:app"]
