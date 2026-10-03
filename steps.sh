#!/usr/bin/env bash
# Helper for the Udacity AgentCore chatbot project.
# Put this file in project/starter and run commands like:  bash steps.sh check
set -euo pipefail

REGION=us-east-1
TOOL_STACK=bug-report-tool-stack
TEST_STACK=bug-report-testing-stack
TABLE=bug-report-tool-stack-bug-reports
cd "$(dirname "$0")"

stack_output() {
  aws cloudformation describe-stacks --stack-name "$1" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

case "${1:-help}" in

  creds)
    # Usage: bash steps.sh creds workspace-user_accessKeys.csv
    csv="${2:?Usage: bash steps.sh creds <your-key-file.csv>}"
    mkdir -p ~/.aws
    line=$(tail -n 1 "$csv" | tr -d '\r"\357\273\277')
    id=${line%%,*}
    secret=${line#*,}; secret=${secret%%,*}
    printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$id" "$secret" > ~/.aws/credentials
    chmod 600 ~/.aws/credentials
    aws configure set region "$REGION"
    aws configure set output json
    rm -f "$csv"
    echo "Key ID length: ${#id} (should be 20)   Secret length: ${#secret} (should be 40)"
    echo "Removed $csv from the project folder."
    if env | grep -q '^AWS_ACCESS_KEY_ID\|^AWS_SECRET_ACCESS_KEY\|^AWS_SESSION_TOKEN'; then
      echo "WARNING: AWS environment variables are set and will override this file. Run:"
      echo "  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN"
    fi
    aws sts get-caller-identity
    ;;

  check)
    echo "== Who am I? =="
    aws sts get-caller-identity
    echo "== Can I reach Nova Pro? =="
    aws bedrock-runtime converse --model-id us.amazon.nova-pro-v1:0 --region "$REGION" \
      --messages '[{"role":"user","content":[{"text":"Say hi in five words."}]}]' \
      --query 'output.message.content[0].text' --output text
    echo "All good."
    ;;

  venv)
    python3 -m venv venv
    venv/bin/pip install -r requirements.txt
    venv/bin/python -c "import boto3; print('boto3', boto3.__version__)"
    echo "Now type:  source venv/bin/activate"
    ;;

  tool)
    aws cloudformation deploy --template-file cloudformation-tool.yaml \
      --stack-name "$TOOL_STACK" --capabilities CAPABILITY_NAMED_IAM --region "$REGION"
    echo "Waiting 30 seconds for IAM roles to propagate..."
    sleep 30
    python setup_gateway.py
    ;;

  scan)
    aws dynamodb scan --table-name "$TABLE" --region "$REGION" \
      --query 'Items[].{Ticket:ticketId.S,Status:status.S,Description:description.S,Environment:environment.S}' \
      --output table
    ;;

  transcript)
    # Usage: bash steps.sh transcript bug_report
    name="${2:?Usage: bash steps.sh transcript <name>}"
    mkdir -p transcripts
    script -q "transcripts/$name.txt" -c "python chat.py"
    echo "Saved transcripts/$name.txt"
    ;;

  dataset)
    python generate-eval-dataset.py --tests-json harness-tests.json
    echo "HARNESS_ERROR count (must be 0): $(grep -c HARNESS_ERROR output_eval_dataset.jsonl || true)"
    ;;

  testing)
    aws cloudformation deploy --template-file cloudformation-testing.yaml \
      --stack-name "$TEST_STACK" --capabilities CAPABILITY_NAMED_IAM --region "$REGION"
    echo "Bucket: $(stack_output "$TEST_STACK" EvalDatasetBucketName)"
    echo "Role:   $(stack_output "$TEST_STACK" BedrockEvalRoleArn)"
    ;;

  eval)
    bucket=$(stack_output "$TEST_STACK" EvalDatasetBucketName)
    role=$(stack_output "$TEST_STACK" BedrockEvalRoleArn)
    [ -f output_eval_dataset.jsonl ] || { echo "Run: bash steps.sh dataset   first"; exit 1; }
    aws s3 cp output_eval_dataset.jsonl "s3://$bucket/output_eval_dataset.jsonl" --region "$REGION"
    job="support-chatbot-eval-$(date +%Y%m%d-%H%M%S)"
    eval_config=$(printf '{"automated":{"datasetMetricConfigs":[{"taskType":"General","dataset":{"name":"support-chatbot-eval-dataset","datasetLocation":{"s3Uri":"s3://%s/output_eval_dataset.jsonl"}},"metricNames":["Builtin.Correctness"]}],"evaluatorModelConfig":{"bedrockEvaluatorModels":[{"modelIdentifier":"amazon.nova-pro-v1:0"}]}}}' "$bucket")
    arn=$(aws bedrock create-evaluation-job \
      --job-name "$job" \
      --role-arn "$role" \
      --evaluation-config "$eval_config" \
      --inference-config '{"models":[{"precomputedInferenceSource":{"inferenceSourceIdentifier":"my-support-chatbot"}}]}' \
      --output-data-config "{\"s3Uri\":\"s3://$bucket/results/\"}" \
      --region "$REGION" --query jobArn --output text)
    echo "$arn" > last_eval_job.txt
    echo "Created evaluation job: $job"
    echo "Check progress with:  bash steps.sh status"
    ;;

  status)
    aws bedrock get-evaluation-job --job-identifier "$(cat last_eval_job.txt)" \
      --region "$REGION" --query '{Name:jobName,Status:status,Failures:failureMessages}' --output table
    ;;

  results)
    bucket=$(stack_output "$TEST_STACK" EvalDatasetBucketName)
    rm -rf eval_results
    aws s3 cp "s3://$bucket/results/" eval_results/ --recursive --region "$REGION" >/dev/null
    python - <<'PY'
import json, pathlib

def find_scores(obj, found):
    if isinstance(obj, dict):
        if "metricName" in obj and "result" in obj:
            found.append((obj["metricName"], obj["result"]))
        for v in obj.values():
            find_scores(v, found)
    elif isinstance(obj, list):
        for v in obj:
            find_scores(v, found)

tests = {t["prompt"]: t["id"] for t in json.load(open("harness-tests.json"))["tests"]}
rows = []
for f in sorted(pathlib.Path("eval_results").rglob("*.jsonl")):
    for line in f.read_text().splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        prompt = (rec.get("inputRecord") or rec).get("prompt", "")
        scores = []
        find_scores(rec.get("automatedEvaluationResult", rec), scores)
        rows.append((tests.get(prompt, prompt[:40]), scores))
if not rows:
    print("No result files yet. Is the job Completed? (bash steps.sh status)")
for test_id, scores in rows:
    print(f"{test_id:28} " + ", ".join(f"{m}: {s}" for m, s in scores))
PY
    ;;

  package)
    python3 - <<'PY'
import pathlib, zipfile
keep_ext = {".py", ".yaml", ".md", ".json", ".jsonl", ".txt", ".sh", ".png", ".jpg", ".jpeg"}
skip_dirs = {"venv", ".git", "__pycache__", ".aws"}
skip_files = {"last_eval_job.txt"}
out = pathlib.Path("submission.zip")
count = 0
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for p in sorted(pathlib.Path(".").rglob("*")):
        if not p.is_file() or p == out:
            continue
        if any(part in skip_dirs for part in p.parts):
            continue
        if p.suffix.lower() not in keep_ext or p.name in skip_files:
            continue
        if "accesskey" in p.name.lower() or p.suffix.lower() == ".csv":
            continue
        z.write(p, pathlib.Path("support-chatbot-project") / p)
        count += 1
        print("  added", p)
print(f"Created submission.zip with {count} files. Right-click it in the explorer and choose Download.")
PY
    ;;

  cleanup)
    python cleanup_agentcore.py || true
    bucket=$(stack_output "$TEST_STACK" EvalDatasetBucketName 2>/dev/null || true)
    [ -n "$bucket" ] && aws s3 rm "s3://$bucket" --recursive --region "$REGION" || true
    aws cloudformation delete-stack --stack-name "$TEST_STACK" --region "$REGION"
    aws cloudformation delete-stack --stack-name "$TOOL_STACK" --region "$REGION"
    echo "Cleanup started. Stacks take a few minutes to delete."
    ;;

  *)
    echo "Commands: creds <file.csv> | check | venv | tool | scan | transcript <name> |"
    echo "          dataset | testing | eval | status | results | package | cleanup"
    ;;
esac
