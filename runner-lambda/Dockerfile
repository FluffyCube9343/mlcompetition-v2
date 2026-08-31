# Runner Lambda as a container image: participant libraries (torch etc.)
# blow past the 250MB zip-Lambda limit; image Lambdas get 10GB.
#
#   docker build -t competition-runner .
#   aws ecr create-repository --repository-name competition-runner
#   docker tag competition-runner:latest <account>.dkr.ecr.<region>.amazonaws.com/competition-runner:latest
#   docker push <account>.dkr.ecr.<region>.amazonaws.com/competition-runner:latest
FROM public.ecr.aws/lambda/python:3.12

# libraries participants may use; h5py covers .h5 (HDF5/Keras) weights
RUN pip install --no-cache-dir \
    numpy \
    pandas \
    scikit-learn \
    safetensors \
    onnxruntime \
    h5py
    # torch --index-url https://download.pytorch.org/whl/cpu   # uncomment if needed

COPY lambda_function.py ${LAMBDA_TASK_ROOT}/

CMD ["lambda_function.handler"]
