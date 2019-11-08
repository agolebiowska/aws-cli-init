#!/bin/bash

S3_ENDPOINT=http://localhost:4572
API_ENDPOINT=http://localhost:4567
DYNAMO_ENDPOINT=http://localhost:4569
IAM_ENDPOINT=http://localhost:4593
LAMBDA_ENDPOINT=http://localhost:4574

STAGE=test
REGION=us-west-1
API_NAME=test-api
BUCKET_NAME=test-bucket
TABLE_NAME=test
IAM_ROLE_NAME=test-iam
LAMBDA_NAME=test-lambda
LAMBDA_FULL_PATH=path/to/zip/file/test.zip

function fail() {
    echo $2
    exit $1
}

echo "Creating s3 bucket: ${BUCKET_NAME}"
aws --endpoint-url=${S3_ENDPOINT} s3api create-bucket --bucket ${BUCKET_NAME} \
    --region ${REGION}

aws --endpoint-url=${S3_ENDPOINT} s3 sync \
    ./app s3://${BUCKET_NAME} \
    --acl public-read

aws --endpoint-url=${S3_ENDPOINT} s3 website s3://${BUCKET_NAME} --index-document index.html

[[ $? == 0 ]] || fail 1 "Failed: AWS | s3 | create-bucket"
echo "Creating s3 bucket: finished"

echo "Creating dynamodb table: ${TABLE_NAME}"
aws --endpoint-url=${DYNAMO_ENDPOINT} dynamodb create-table --table-name ${TABLE_NAME} \
    --attribute-definitions AttributeName=RideId,AttributeType=S \
    --key-schema AttributeName=RideId,KeyType=HASH \
    --provisioned-throughput ReadCapacityUnits=1000,WriteCapacityUnits=1000 \
    --region ${REGION}

[[ $? == 0 ]] || fail 2 "Failed: AWS | dynamodb | create-table"
echo "Creating dynamodb table: finished"

echo "Creating IAM role: ${IAM_ROLE_NAME}"
aws --endpoint-url=${IAM_ENDPOINT} iam create-role --role-name ${IAM_ROLE_NAME} \
    --assume-role-policy-document ./lambdaTrustPolicy.json

aws --endpoint-url=${IAM_ENDPOINT} iam attach-role-policy --role-name ${IAM_ROLE_NAME} \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

aws --endpoint-url=${IAM_ENDPOINT} iam put-role-policy --role-name ${IAM_ROLE_NAME} \
    --policy-name permissionsPolicyForDynamoDB \
    --policy-document ./permissionsPolicyForDynamoDB.json
echo "Creating IAM role: finished"

echo "Creating lambda function: ${LAMBDA_NAME}"
aws --endpoint-url=${LAMBDA_ENDPOINT} lambda create-function --function-name ${LAMBDA_NAME} \
  --zip-file fileb:///${LAMBDA_FULL_PATH} \
  --handler requestUnicorn.handler \
  --runtime nodejs8.10 \
  --role arn:aws:iam::000000000000:role/WildRydesLambda \
  --region ${REGION}

[[ $? == 0 ]] || fail 3 "Failed: AWS | lambda | create-function"

LAMBDA_ARN=$(awslocal lambda list-functions --query "Functions[?FunctionName==\`${LAMBDA_NAME}\`].FunctionArn" --output text)
echo "Creating lambda function: finished"

echo "Creating API Gateway: ${API_NAME}"
aws --endpoint-url=${API_ENDPOINT} apigateway create-rest-api --name ${API_NAME} \
    --region ${REGION}

[[ $? == 0 ]] || fail 4 "Failed: AWS | apigateway | create-rest-api"

API_ID=$(aws --endpoint-url=${API_ENDPOINT} apigateway get-rest-apis --query "items[?name==\`${API_NAME}\`].id" --output text)
PARENT_RESOURCE_ID=$(aws --endpoint-url=${API_ENDPOINT} apigateway get-resources --rest-api-id ${API_ID} --query 'items[?path==`/`].id' --output text)
echo "Creating API Gateway: finished"

echo "Creating API resource: ${API_NAME}"
aws --endpoint-url=${API_ENDPOINT} apigateway create-resource --rest-api-id ${API_ID} \
    --parent-id ${PARENT_RESOURCE_ID} --path-part ride \
    --region ${REGION}

[[ $? == 0 ]] || fail 5 "Failed: AWS | apigateway | create-resource"

RESOURCE_ID=$(aws --endpoint-url=${API_ENDPOINT} apigateway get-resources --rest-api-id ${API_ID} --query 'items[?path==`/ride`].id' --output text)
echo "Creating API resource: finished"

echo "Creating GET method"
aws --endpoint-url=${API_ENDPOINT} apigateway put-method \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method GET \
    --authorization-type NONE \
    --region ${REGION} \

[[ $? == 0 ]] || fail 6 "Failed: AWS | apigateway | put-method"
echo "Creating POST method: finished"

echo "Creating integration"
aws --endpoint-url=${API_ENDPOINT} apigateway put-integration \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method GET \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations \
    --passthrough-behavior WHEN_NO_MATCH \
    --region ${REGION} \

[[ $? == 0 ]] || fail 7 "Failed: AWS | apigateway | put-integration"
echo "Creating integration: finished"

echo "Creating deployment"
aws --endpoint-url=${API_ENDPOINT} apigateway create-deployment \
    --rest-api-id ${API_ID} \
    --stage-name ${STAGE} \
    --region ${REGION}

[[ $? == 0 ]] || fail 8 "Failed: AWS | apigateway | create-deployment"
echo "Creating deployment: finished"

ENDPOINT=${API_ENDPOINT}/restapis/${API_ID}/${STAGE}/_user_request_/test

echo "API available at: ${ENDPOINT}"

echo "Testing GET:"
curl -i ${ENDPOINT}

echo "Testing POST:"
curl -iX POST ${ENDPOINT}

echo "Localstack initialization finished"