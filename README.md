# gitops-istio

This guide walks you through setting up Istio on a Kubernetes cluster and 
automating A/B testing and canary releases with GitOps pipelines.

![Progressive Delivery GitOps Pipeline](https://raw.githubusercontent.com/weaveworks/flagger/master/docs/diagrams/flagger-gitops-istio.png)

Components:

* **Istio** service mesh
    * manages the traffic flows between microservices, enforcing access policies and aggregating telemetry data
* **Prometheus** monitoring system  
    * time series database that collects and stores the service mesh metrics
* **Flux** GitOps operator
    * syncs YAMLs and Helm charts between git and clusters
    * scans container registries and deploys new images
* **Helm Operator** CRD controller
    * automates Helm chart releases
* **Flagger** progressive delivery operator
    * automates the release process using Istio routing for traffic shifting and Prometheus metrics for canary analysis

### Prerequisites

You'll need a Kubernetes cluster **v1.11** or newer with `LoadBalancer` support. 
For testing purposes you can use Minikube with four CPUs and 4GB of memory. 

Install Flux CLI and Helm v3:

```bash
brew install fluxctl helm
```

Fork this repository and clone it:

```bash
git clone https://github.com/<YOUR-USERNAME>/gitops-istio
cd gitops-istio
```

### Cluster bootstrap

Install Flux and its Helm Operator by specifying your fork URL:

```bash
./scripts/flux-init.sh git@github.com:<YOUR-USERNAME>/gitops-istio
```

At startup, Flux generates a SSH key and logs the public key. The above command will print the public key. 

In order to sync your cluster state with git you need to copy the public key and create a deploy key with write 
access on your GitHub repository. On GitHub go to _Settings > Deploy keys_ click on _Add deploy key_, 
check _Allow write access_, paste the Flux public key and click _Add key_.

When Flux has write access to your repository it will do the following:

* installs the Istio operator
* waits for Istio control plane to be ready
* installs Flagger CRDs and Helm Releases
* creates the Istio public gateway
* creates the `prod` namespace
* creates the load tester deployment
* creates the frontend deployment and canary
* creates the backend deployment and canary

![Flux Istio Operator](https://raw.githubusercontent.com/fluxcd/helm-operator-get-started/master/diagrams/flux-istio-operator.png)

You can customize the Istio installation with the `IstioOperator` resource located at
[istio/control-plane.yaml](https://github.com/stefanprodan/gitops-istio/blob/master/istio/control-plane.yaml):

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
  name: istio-default
spec:
  profile: default
  components:
    pilot:
      k8s:
        resources:
          requests:
            cpu: 10m
            memory: 100Mi
```

After modifying the Istio settings, you can push the change to git and Flux will apply it on the cluster. 
The Istio operator will reconfigure the Istio control plane according to your changes.
It can take a couple of minutes for Flux to sync and apply the changes, to speed up the apply
you can use `fluxctl sync` to trigger a git sync.

### Workloads bootstrap

When Flux syncs the Git repository with your cluster, it creates the frontend/backend deployment, HPA and a canary object.
Flagger uses the canary definition to create a series of objects: Kubernetes deployments, 
ClusterIP services, Istio destination rules and virtual services. These objects expose the application on the mesh and drive 
the canary analysis and promotion.

```bash
# applied by Flux
deployment.apps/frontend
horizontalpodautoscaler.autoscaling/frontend
canary.flagger.app/frontend

# generated by Flagger
deployment.apps/frontend-primary
horizontalpodautoscaler.autoscaling/frontend-primary
service/frontend
service/frontend-canary
service/frontend-primary
destinationrule.networking.istio.io/frontend-canary
destinationrule.networking.istio.io/frontend-primary
virtualservice.networking.istio.io/frontend
```

Check if Flagger has successfully initialized the canaries: 

```
kubectl -n prod get canaries

NAME       STATUS        WEIGHT
backend    Initialized   0
frontend   Initialized   0
```

When the `frontend-primary` deployment comes online, 
Flagger will route all traffic to the primary pods and scale to zero the `frontend` deployment.

Find the Istio ingress gateway address with:

```bash
kubectl -n istio-system get svc istio-ingressgateway -ojson | jq .status.loadBalancer.ingress
```

Open a browser and navigate to the ingress address, you'll see the frontend UI.

### Canary releases

Flagger implements a control loop that gradually shifts traffic to the canary while measuring key performance indicators
like HTTP requests success rate, requests average duration and pod health.
Based on analysis of the KPIs a canary is promoted or aborted, and the analysis result is published to Slack.

A canary analysis is triggered by changes in any of the following objects:
* Deployment PodSpec (container image, command, ports, env, etc)
* ConfigMaps and Secrets mounted as volumes or mapped to environment variables

For workloads that are not receiving constant traffic Flagger can be configured with a webhook, 
that when called, will start a load test for the target workload. The canary configuration can be found
at [prod/backend/canary.yaml](https://github.com/stefanprodan/gitops-istio/blob/master/prod/backend/canary.yaml).

![Flagger Canary Release](https://raw.githubusercontent.com/weaveworks/flagger/master/docs/diagrams/flagger-canary-steps.png)

Trigger a canary deployment for the backend app by updating the container image:

```bash
$ export FLUX_FORWARD_NAMESPACE=flux

$ fluxctl release --workload=prod:deployment/backend \
--update-image=stefanprodan/podinfo:3.1.1

Submitting release ...
WORKLOAD                 STATUS   UPDATES
prod:deployment/backend  success  backend: stefanprodan/podinfo:3.1.0 -> 3.1.1
Commit pushed:	ccb4ae7
Commit applied:	ccb4ae7
```

Flagger detects that the deployment revision changed and starts a new rollout:

```bash
$ kubectl -n prod describe canary backend

Events:

New revision detected! Scaling up backend.prod
Starting canary analysis for backend.prod
Pre-rollout check conformance-test passed
Advance backend.prod canary weight 5
...
Advance backend.prod canary weight 50
Copying backend.prod template spec to backend-primary.prod
Promotion completed! Scaling down backend.prod
```

During the analysis the canary???s progress can be monitored with Grafana. You can access the dashboard using port forwarding:

```bash
kubectl -n istio-system port-forward svc/flagger-grafana 3000:80
```

The Istio dashboard URL is 
http://localhost:3000/d/flagger-istio/istio-canary?refresh=10s&orgId=1&var-namespace=prod&var-primary=backend-primary&var-canary=backend

![Canary Deployment](https://raw.githubusercontent.com/weaveworks/flagger/master/docs/screens/demo-backend-dashboard.png)

Note that if new changes are applied to the deployment during the canary analysis, Flagger will restart the analysis phase.

### A/B testing

Besides weighted routing, Flagger can be configured to route traffic to the canary based on HTTP match conditions. 
In an A/B testing scenario, you'll be using HTTP headers or cookies to target a certain segment of your users. 
This is particularly useful for frontend applications that require session affinity.

You can enable A/B testing by specifying the HTTP match conditions and the number of iterations:

```yaml
  analysis:
    # schedule interval (default 60s)
    interval: 10s
    # max number of failed metric checks before rollback
    threshold: 10
    # total number of iterations
    iterations: 12
    # canary match condition
    match:
      - headers:
          user-agent:
            regex: ".*Firefox.*"
      - headers:
          cookie:
            regex: "^(.*?;)?(type=insider)(;.*)?$"
```

The above configuration will run an analysis for two minutes targeting Firefox users and those that 
have an insider cookie. The frontend configuration can be found at `prod/frontend/canary.yaml`.

Trigger a deployment by updating the frontend container image:

```bash
$ fluxctl release --workload=prod:deployment/frontend \
--update-image=stefanprodan/podinfo:3.1.1
```

Flagger detects that the deployment revision changed and starts the A/B testing:

```bash
$ kubectl -n istio-system logs deploy/flagger -f | jq .msg

New revision detected! Scaling up frontend.prod
Waiting for frontend.prod rollout to finish: 0 of 1 updated replicas are available
Pre-rollout check conformance-test passed
Advance frontend.prod canary iteration 1/10
...
Advance frontend.prod canary iteration 10/10
Copying frontend.prod template spec to frontend-primary.prod
Waiting for frontend-primary.prod rollout to finish: 1 of 2 updated replicas are available
Promotion completed! Scaling down frontend.prod
```

You can monitor all canaries with:

```bash
$ watch kubectl get canaries --all-namespaces

NAMESPACE   NAME      STATUS        WEIGHT
prod        frontend  Progressing   100
prod        backend   Succeeded     0
```

### Rollback based on Istio metrics

Flagger makes use of the metrics provided by Istio telemetry to validate the canary workload.
The frontend app [analysis](https://github.com/stefanprodan/gitops-istio/blob/master/prod/frontend/canary.yaml)
defines two metric checks: 

```yaml
    metrics:
      - name: error-rate
        templateRef:
          name: error-rate
          namespace: istio-system
        thresholdRange:
          max: 1
        interval: 30s
      - name: latency
        templateRef:
          name: latency
          namespace: istio-system
        thresholdRange:
          max: 500
        interval: 30s
```

The Prometheus queries used for checking the error rate and latency are located at
[flagger/istio-metrics.yaml](https://github.com/stefanprodan/gitops-istio/blob/master/flagger/istio-metrics.yaml).

During the canary analysis you can generate HTTP 500 errors and high latency to test Flagger's rollback.

Generate HTTP 500 errors:

```bash
watch curl -b 'type=insider' http://<INGRESS-IP>/status/500
```

Generate latency:

```bash
watch curl -b 'type=insider' http://<INGRESS-IP>/delay/1
```

When the number of failed checks reaches the canary analysis threshold, the traffic is routed back to the primary, 
the canary is scaled to zero and the rollout is marked as failed.

```text
$ kubectl -n istio-system logs deploy/flagger -f | jq .msg

New revision detected! Scaling up frontend.prod
Pre-rollout check conformance-test passed
Advance frontend.prod canary iteration 1/10
Halt frontend.prod advancement error-rate 31 > 1
Halt frontend.prod advancement latency 2000 > 500
...
Rolling back frontend.prod failed checks threshold reached 10
Canary failed! Scaling down frontend.prod
```

You can extend the analysis with custom metric checks targeting
[Prometheus](https://docs.flagger.app/usage/metrics#prometheus),
[Datadog](https://docs.flagger.app/usage/metrics#datadog) and
[Amazon CloudWatch](https://docs.flagger.app/usage/metrics#amazon-cloudwatch).

### Alerting

Flagger can be configured to send Slack notifications.
You can enable alerting by adding the Slack settings to Flagger's Helm Release:

```yaml
apiVersion: helm.fluxcd.io/v1
kind: HelmRelease
metadata:
  name: flagger
  namespace: istio-system
spec:
  values:
    slack:
      user: flagger
      channel: general
      url: https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK
```

Once configured with a Slack incoming **webhook**, Flagger will post messages when a canary deployment 
has been initialised, when a new revision has been detected and if the canary analysis failed or succeeded.

![Slack Notifications](https://raw.githubusercontent.com/weaveworks/flagger/master/docs/screens/slack-canary-notifications.png)

A canary deployment will be rolled back if the progress deadline exceeded or if the analysis reached the 
maximum number of failed checks:

![Slack Notifications](https://raw.githubusercontent.com/weaveworks/flagger/master/docs/screens/slack-canary-failed.png)

For configuring alerting at canary level for Slack, MS Teams, Discord or Rocket see the [docs](https://docs.flagger.app/usage/alerting#canary-configuration).

### Getting Help

If you have any questions about progressive delivery:

* Invite yourself to the [Weave community slack](https://slack.weave.works/)
  and join the [#flux](https://weave-community.slack.com/messages/flux/) and [#flagger](https://weave-community.slack.com/messages/flagger/) channel.
* Join the [Weave User Group](https://www.meetup.com/pro/Weave/) and get invited to online talks,
  hands-on training and meetups in your area.

Your feedback is always welcome!