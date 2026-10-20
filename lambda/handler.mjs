import { ECSClient, DescribeServicesCommand, UpdateServiceCommand } from "@aws-sdk/client-ecs";
import {
  ElasticLoadBalancingV2Client,
  DescribeTargetHealthCommand,
  ModifyRuleCommand,
} from "@aws-sdk/client-elastic-load-balancing-v2";
import {
  ApplicationAutoScalingClient,
  RegisterScalableTargetCommand,
} from "@aws-sdk/client-application-auto-scaling";

const ecs = new ECSClient();
const elbv2 = new ElasticLoadBalancingV2Client();
const autoscaling = new ApplicationAutoScalingClient();

const CLUSTER = process.env.CLUSTER_NAME;
const SERVICE = process.env.SERVICE_NAME;
const ECS_TARGET_GROUP_ARN = process.env.ECS_TARGET_GROUP_ARN;
const LAMBDA_TARGET_GROUP_ARN = process.env.LAMBDA_TARGET_GROUP_ARN;
const RULE_ARNS = (process.env.LISTENER_RULE_ARNS || "").split(",").filter(Boolean);
const RESOURCE_ID = process.env.RESOURCE_ID;
const MIN_CAPACITY = Number(process.env.MIN_CAPACITY);
const MAX_CAPACITY = Number(process.env.MAX_CAPACITY);
const IDLE_ALARM_NAME = process.env.IDLE_ALARM_NAME;
const NO_TASKS_ALARM_NAME = process.env.NO_TASKS_ALARM_NAME;

export async function handler(event, context) {
  if (isAlbEvent(event)) {
    try {
      return await wake(event, context);
    } catch (error) {
      console.log(JSON.stringify({ action: "wake_failed", error: String(error) }));
      return html(503, "503 Service Unavailable", "El servicio no pudo iniciarse. Reintente en unos segundos.");
    }
  }

  const [alarmName, state] = alarm(event);
  if (state !== "ALARM") {
    return { action: "ignore", alarm: alarmName, state };
  }
  if (alarmName === IDLE_ALARM_NAME) {
    return sleep();
  }
  if (alarmName === NO_TASKS_ALARM_NAME) {
    return ensureLambdaRoute();
  }
  return { action: "ignore", alarm: alarmName, state };
}

async function wake(event, context) {
  await setScaleInSuspended(true);
  const service = await describeService();
  if (service.desiredCount < 1) {
    await ecs.send(new UpdateServiceCommand({ cluster: CLUSTER, service: SERVICE, desiredCount: 1 }));
    console.log(JSON.stringify({ action: "desired_count", value: 1 }));
  }

  if (!(await waitUntilHealthy(context))) {
    console.log(JSON.stringify({ action: "still_starting" }));
    return html(503, "503 Service Unavailable", "El servicio se está iniciando. Reintente en unos segundos.");
  }

  await forwardRules(ECS_TARGET_GROUP_ARN);
  await setScaleInSuspended(false);
  return redirect(event);
}

async function sleep() {
  const service = await describeService();
  if (service.pendingCount > 0 || (service.desiredCount >= 1 && service.runningCount === 0)) {
    console.log(JSON.stringify({ action: "sleep_skipped", reason: "service is starting" }));
    return { action: "sleep_skipped" };
  }

  await forwardRules(LAMBDA_TARGET_GROUP_ARN);
  await setScaleInSuspended(true);
  try {
    if (service.desiredCount !== 0) {
      await ecs.send(new UpdateServiceCommand({ cluster: CLUSTER, service: SERVICE, desiredCount: 0 }));
      console.log(JSON.stringify({ action: "desired_count", value: 0 }));
    }
  } finally {
    await setScaleInSuspended(false);
  }
  return { action: "asleep" };
}

async function ensureLambdaRoute() {
  const service = await describeService();
  if (service.desiredCount > 0 || service.runningCount > 0 || service.pendingCount > 0) {
    return { action: "route_unchanged" };
  }
  await forwardRules(LAMBDA_TARGET_GROUP_ARN);
  return { action: "route_lambda" };
}

async function describeService() {
  const result = await ecs.send(new DescribeServicesCommand({ cluster: CLUSTER, services: [SERVICE] }));
  const service = (result.services || [])[0];
  if (!service || service.status === "INACTIVE") {
    throw new Error(`ECS service ${SERVICE} was not found`);
  }
  return service;
}

async function waitUntilHealthy(context) {
  while (context.getRemainingTimeInMillis() > 5000) {
    const health = await elbv2.send(new DescribeTargetHealthCommand({ TargetGroupArn: ECS_TARGET_GROUP_ARN }));
    const states = (health.TargetHealthDescriptions || []).map((item) => item.TargetHealth.State);
    if (states.includes("healthy")) {
      return true;
    }
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  return false;
}

async function forwardRules(targetGroupArn) {
  for (const ruleArn of RULE_ARNS) {
    await elbv2.send(new ModifyRuleCommand({
      RuleArn: ruleArn,
      Actions: [{ Type: "forward", TargetGroupArn: targetGroupArn }],
    }));
  }
  console.log(JSON.stringify({ action: "rules_forward", targetGroupArn, rules: RULE_ARNS.length }));
}

async function setScaleInSuspended(suspended) {
  await autoscaling.send(new RegisterScalableTargetCommand({
    ServiceNamespace: "ecs",
    ResourceId: RESOURCE_ID,
    ScalableDimension: "ecs:service:DesiredCount",
    MinCapacity: MIN_CAPACITY,
    MaxCapacity: MAX_CAPACITY,
    SuspendedState: {
      DynamicScalingInSuspended: suspended,
      DynamicScalingOutSuspended: false,
      ScheduledScalingSuspended: false,
    },
  }));
}

function redirect(event) {
  const proto = header(event, "x-forwarded-proto") || "https";
  const host = header(event, "host");
  if (!host) {
    return html(503, "503 Service Unavailable", "El servicio está listo. Reintente la solicitud.");
  }
  const path = event.path || "/";
  const query = event.queryStringParameters || {};
  const suffix = Object.keys(query).length > 0 ? `?${new URLSearchParams(query).toString()}` : "";
  return response(307, "307 Temporary Redirect", "", { location: `${proto}://${host}${path}${suffix}` });
}

function html(status, description, message) {
  const body = `<!DOCTYPE html><html><body><p>${message}</p></body></html>`;
  return response(status, description, body, { "retry-after": "10", "content-type": "text/html; charset=utf-8" });
}

function response(status, description, body, headers) {
  return {
    isBase64Encoded: false,
    statusCode: status,
    statusDescription: description,
    headers,
    body,
  };
}

function header(event, name) {
  for (const [key, value] of Object.entries(event.headers || {})) {
    if (key.toLowerCase() === name && value) {
      return value;
    }
  }
  for (const [key, value] of Object.entries(event.multiValueHeaders || {})) {
    if (key.toLowerCase() === name && value?.[0]) {
      return value[0];
    }
  }
  return "";
}

function isAlbEvent(event) {
  return event.requestContext != null && typeof event.requestContext === "object" && "elb" in event.requestContext;
}

function alarm(event) {
  const data = event.alarmData || {};
  if (Object.keys(data).length > 0) {
    return [data.alarmName, data.state?.value];
  }
  return [event.AlarmName, event.NewStateValue];
}
