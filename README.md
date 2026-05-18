# AWS Exec Runbook

This runbook documents how to configure AWS SSO, set up profiles, and exec into running workloads on **ECS** (`aws ecs execute-command`) or **EKS** (`kubectl exec`) via AWS CLI.

---

## 🔑 SSO & Profiles

1. Configure SSO profile:
   ```bash
   aws configure sso --profile corp-sso
   ```

2. Generate per-account profiles (using your helper script):
   ```bash
   ./generate-profiles.sh
   ```

3. Login with the desired profile:
   ```bash
   aws sso login --profile <profile>
   ```

4. View all configured profiles:
   ```bash
   cat ~/.aws/config
   ```

⚠️ **Important:** The profile name in `~/.aws/config` must exactly match what you pass in `--profile`.

---

### ⚡️ Shortcut: ECS helper script

If you don't want to manually look up clusters/tasks every time, use the helper script instead. It auto-discovers the cluster and running task and drops you straight into the `web` container.

```bash
# make it executable once
chmod +x ./ecs-exec.sh

# minimal: pick cluster & task interactively
./ecs-exec.sh --profile <profile>

# with explicit region (if your profile doesn't set one)
./ecs-exec.sh --profile <profile> --region eu-west-2

# skip prompts by specifying cluster/task
./ecs-exec.sh --profile <profile> --cluster <cluster-name-or-arn> --task <task-arn>

# use bash instead of sh if the image has it
./ecs-exec.sh --profile <profile> --shell /bin/bash
```

### ⚡️ Shortcut: EKS helper script

For EKS, `eks-exec.sh` walks you through cluster → namespace → pod → container and then runs `kubectl exec -it`. It updates your kubeconfig under a profile-scoped context alias (`<profile>-<cluster>`) so it won't clobber existing contexts.

```bash
# make it executable once
chmod +x ./eks-exec.sh

# minimal: pick everything interactively
./eks-exec.sh --profile <profile>

# with explicit region (if your profile doesn't set one)
./eks-exec.sh --profile <profile> --region eu-west-2

# skip prompts by specifying any of: cluster / namespace / pod / container
./eks-exec.sh --profile <profile> --cluster <cluster-name> --namespace <ns> --pod <pod> --container <name>

# use sh instead of bash if the image is slim
./eks-exec.sh --profile <profile> --shell /bin/sh
```

Requires `kubectl` and `jq` in addition to the AWS CLI (no Session Manager plugin needed for EKS).

## 🔎 ECS Discovery

Alternatively you can go down this route if you need to find multiple different containers/ tasks
1. List all clusters:
   ```bash
   aws ecs list-clusters --profile <profile>
   ```

2. List tasks in a cluster:
   ```bash
   aws ecs list-tasks --cluster <cluster-name> --profile <profile>
   ```

⚠️ Use either the **cluster name** (`pwcuat`) or the **full ARN**. Do **not** use `cluster/<name>`.

---

## 🚀 Exec into a Container

Run the command:

```bash
aws ecs execute-command   --cluster <cluster-name-or-arn>   --task <task-arn>   --container <container-name>   --command "/bin/sh"   --interactive   --region <region>   --profile <profile>
```

### Pre-requisites

1. **Enable ECS Exec** on the service/cluster:
   ```bash
   aws ecs update-service      --cluster <cluster-name>      --service <service-name>      --enable-execute-command
   ```

   Or enable at service creation time with `--enable-execute-command`.

2. **Cluster configuration** must have ECS Exec enabled:
   ```bash
   aws ecs describe-clusters      --clusters <cluster>      --include CONFIGURATIONS      --profile <profile>
   ```
   If `executeCommandConfiguration` is empty, configure it with:
   ```bash
   aws ecs update-cluster-configuration      --cluster <cluster>      --execute-command-configuration "logging=DEFAULT"
   ```

3. **Task execution role permissions** must include:
   ```json
   {
     "Effect": "Allow",
     "Action": [
       "ssmmessages:*",
       "ssm:UpdateInstanceInformation",
       "ec2messages:*",
       "logs:CreateLogStream",
       "logs:PutLogEvents",
       "kms:Decrypt",
       "kms:GenerateDataKey"
     ],
     "Resource": "*"
   }
   ```

4. Ensure your **AWS CLI version ≥ 2.1.29**.

---

## 🛠 Tooling

Install the Session Manager plugin if not already installed:

- **macOS**
  ```bash
  brew install session-manager-plugin
  ```

- **Linux (Debian/Ubuntu)**
  ```bash
  curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o session-manager-plugin.deb
  sudo dpkg -i session-manager-plugin.deb
  ```

Verify:
```bash
session-manager-plugin --version
```

---

## ✅ Final Checklist

- [ ] Logged in with correct SSO profile.  
- [ ] ECS cluster + service have Exec enabled.  
- [ ] Task execution role has required SSM + logs + KMS permissions.  
- [ ] Session Manager plugin installed.  
- [ ] Running `aws ecs execute-command` with **cluster name or ARN**, not `cluster/<name>`.  
- [ ] CLI version is up to date.  

Once all of the above are true, `aws ecs execute-command` should drop you into a shell inside your ECS container.
