/**
 * AitherZero TypeScript Type Definitions
 * Designed for AitherOS Agent Integration
 */

// Agent Types - AitherOS Agents
export type AgentStatus = 'running' | 'stopped' | 'starting' | 'error' | 'idle';
export type AgentCategory = 'automation' | 'infrastructure' | 'narrative' | 'custom';

export interface AitherAgent {
  id: string;
  name: string;
  category: AgentCategory;
  status: AgentStatus;
  // AitherOS agents can use any model dynamically
  currentModel?: string;
  availableModels?: string[];
  persona?: string;
  endpoint?: string;
  workingDirectory?: string;
  lastActive?: string;
  metrics?: AgentMetrics;
  config?: AgentConfig;
  // Tools and capabilities
  tools?: string[];
  prompts?: string[];
  hasWorkflows?: boolean;
  hasMCPClient?: boolean;
}

export interface AgentConfig {
  debugMode?: boolean;
  safetyMode?: boolean;
  memoryEnabled?: boolean;
  [key: string]: unknown;
}

export interface AgentMetrics {
  tokensProcessed: number;
  requestsHandled: number;
  avgLatencyMs: number;
  errorRate: number;
  uptime: number;
  systemLoad?: string;
  gitStatus?: string;
  visionStatus?: string;
}

// Persona Types (from NarrativeAgent)
export interface Persona {
  id: string;
  name: string;
  description: string;
  instruction?: string;
  loraMap?: Record<string, string>;
}

// Legacy alias for backward compatibility
export type Agent = AitherAgent;
export type AgentType = AgentCategory;

// Pipeline Types
export type PipelineStatus = 'pending' | 'running' | 'success' | 'failed' | 'cancelled';
export type StageStatus = 'pending' | 'running' | 'success' | 'failed' | 'skipped';

export interface PipelineStage {
  id: string;
  name: string;
  status: StageStatus;
  duration?: number;
  output?: string;
  error?: string;
}

export interface Pipeline {
  id: string;
  name: string;
  status: PipelineStatus;
  stages: PipelineStage[];
  branch?: string;
  commit?: string;
  triggeredBy?: string;
  startedAt?: string;
  completedAt?: string;
  duration?: number;
}

// Infrastructure Types
export type InfraStatus = 'unknown' | 'planning' | 'applying' | 'destroying' | 'ready' | 'error';

export interface InfraResource {
  id: string;
  type: string;
  name: string;
  provider: string;
  status: 'created' | 'updated' | 'deleted' | 'unchanged';
}

export interface InfraState {
  id: string;
  name: string;
  status: InfraStatus;
  provider: 'terraform' | 'opentofu' | 'pulumi';
  resources: InfraResource[];
  lastApplied?: string;
  planOutput?: string;
}

// Repository Types
export interface Repository {
  id: string;
  name: string;
  fullName: string;
  url: string;
  branch: string;
  lastSync?: string;
  components: RepositoryComponent[];
}

export interface RepositoryComponent {
  type: 'agent' | 'pipeline' | 'playbook' | 'script' | 'config';
  path: string;
  name: string;
  discovered: boolean;
}

// Configuration Types
export type ConfigFormat = 'yaml' | 'json' | 'toml' | 'hcl' | 'psd1';

export interface ConfigFile {
  id: string;
  name: string;
  path: string;
  format: ConfigFormat;
  content: string;
  lastModified?: string;
}

// Remote Endpoint Types
export type EndpointStatus = 'connected' | 'disconnected' | 'connecting' | 'error';

export interface RemoteEndpoint {
  id: string;
  name: string;
  host: string;
  port: number;
  user: string;
  status: EndpointStatus;
  osInfo?: string;
  lastConnected?: string;
  deployedComponents?: string[];
}

// CLI Types
export interface CLICommand {
  id: string;
  command: string;
  output: string;
  exitCode: number;
  startedAt: string;
  completedAt?: string;
  endpoint?: string;
}

// Log Types
export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface LogEntry {
  id: string;
  timestamp: string;
  level: LogLevel;
  message: string;
  source?: string;
  metadata?: Record<string, unknown>;
}

// Dashboard State
export interface DashboardState {
  agents: Agent[];
  pipelines: Pipeline[];
  infrastructure: InfraState[];
  repositories: Repository[];
  configs: ConfigFile[];
  remotes: RemoteEndpoint[];
  cliHistory: CLICommand[];
  logs: LogEntry[];
}

// GitHub API Types
export interface GitHubTree {
  path: string;
  type: 'blob' | 'tree';
  sha: string;
  size?: number;
  url: string;
}

export interface GitHubRepo {
  id: number;
  name: string;
  full_name: string;
  description: string | null;
  html_url: string;
  default_branch: string;
  private: boolean;
}

// Workflow Types
export interface WorkflowTemplate {
  id: string;
  name: string;
  description: string;
  category: 'refactor' | 'testing' | 'data' | 'security' | 'build' | 'custom';
  yaml: string;
  parameters: WorkflowParameter[];
  estimatedCost: number;
  deployCount: number;
}

export interface WorkflowParameter {
  name: string;
  type: 'string' | 'number' | 'boolean' | 'select';
  default?: string | number | boolean;
  options?: string[];
  required: boolean;
}

export interface WorkflowExecution {
  id: string;
  templateId: string;
  status: 'queued' | 'in_progress' | 'completed' | 'failed';
  startedAt: string;
  completedAt?: string;
  parameters: Record<string, unknown>;
  logs?: string;
  artifacts?: string[];
}

// MCP Types
export interface MCPServer {
  id: string;
  name: string;
  url: string;
  type: 'aither' | 'aithernode' | 'custom' | 'github' | 'filesystem' | 'terminal';
  status: 'online' | 'offline' | 'degraded' | 'connected' | 'disconnected' | 'error';
  apiKey?: string;
  tools: MCPTool[];
  lastHealthCheck?: string;
}

export interface MCPTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export interface MCPExecution {
  id: string;
  serverId: string;
  toolName: string;
  args: Record<string, unknown>;
  result?: unknown;
  error?: string;
  status: 'running' | 'success' | 'error';
  timestamp: string;
  duration?: number;
}

// Infrastructure Diagram Types (Nano Banana)
export type DiagramNodeType = 
  | 'compute' | 'storage' | 'network' | 'database' | 'container' 
  | 'serverless' | 'loadbalancer' | 'cdn' | 'dns' | 'firewall'
  | 'vpn' | 'gateway' | 'queue' | 'cache' | 'monitoring';

export type CloudProvider = 'aws' | 'azure' | 'gcp' | 'oci' | 'custom';

export interface DiagramNode {
  id: string;
  type: DiagramNodeType;
  name: string;
  provider: CloudProvider;
  position: { x: number; y: number };
  config: Record<string, unknown>;
  resourceType?: string; // e.g., "aws_instance", "azurerm_virtual_machine"
  region?: string;
  size?: string;
  tags?: Record<string, string>;
}

export interface DiagramConnection {
  id: string;
  sourceId: string;
  targetId: string;
  type: 'network' | 'data' | 'dependency' | 'peering';
  label?: string;
  bidirectional?: boolean;
}

export interface InfraDiagram {
  id: string;
  name: string;
  description?: string;
  nodes: DiagramNode[];
  connections: DiagramConnection[];
  provider: CloudProvider;
  createdAt: string;
  updatedAt: string;
  terraformConfig?: string;
  validated?: boolean;
}

// E2E Workflow Types
export type WorkflowStepStatus = 'pending' | 'running' | 'success' | 'failed' | 'skipped';

export interface E2EWorkflowStep {
  id: string;
  name: string;
  command: string;
  status: WorkflowStepStatus;
  output?: string;
  error?: string;
  duration?: number;
  startedAt?: string;
  completedAt?: string;
}

export interface E2EWorkflow {
  id: string;
  name: string;
  description?: string;
  steps: E2EWorkflowStep[];
  status: 'idle' | 'running' | 'completed' | 'failed';
  configPath?: string;
  infraRepoPath?: string;
  createdAt: string;
  startedAt?: string;
  completedAt?: string;
}

// PowerShell Config Types
export interface PSD1Config {
  projectName: string;
  environment: 'development' | 'staging' | 'production';
  provider: CloudProvider;
  region: string;
  infraRepoPath: string;
  stateBucket?: string;
  stateKey?: string;
  variables: Record<string, string | number | boolean>;
  tags: Record<string, string>;
  playbookPath?: string;
  postDeployScripts?: string[];
}

export interface BootstrapState {
  configPath: string;
  config?: PSD1Config;
  validated: boolean;
  validationErrors?: string[];
  workflowId?: string;
  lastRun?: string;
}

// Credit Tracking Types (Aither Trainer)
export interface CreditAllocation {
  category: 'generative-ai' | 'vertex-workbench' | 'vertex-compute' | 'cloud-run';
  allocated: number;
  used: number;
}

export interface DataJob {
  id: string;
  name: string;
  model: string;
  rowsGenerated: number;
  tokensConsumed: number;
  cost: number;
  status: 'pending' | 'running' | 'completed' | 'failed';
  createdAt: string;
  completedAt?: string;
}

export interface BenchmarkRun {
  id: string;
  name: string;
  localModel: string;
  judgeModel: string;
  testCases: number;
  passRate: number;
  cost: number;
  createdAt: string;
}

export interface AitherTrainerState {
  totalCredits: number;
  remainingCredits: number;
  allocations: CreditAllocation[];
  dataJobs: DataJob[];
  benchmarks: BenchmarkRun[];
  dailyBurn: number;
  projectedDepletion?: string;
}

// Local Model Types
export type LocalModelStatus = 'available' | 'downloading' | 'running' | 'stopped' | 'error' | 'ready';
export type LocalModelProvider = 'ollama' | 'lmstudio' | 'llamacpp' | 'vllm' | 'custom';

export interface LocalModel {
  id: string;
  name: string;
  displayName: string;
  provider: LocalModelProvider;
  status: LocalModelStatus;
  size?: string;
  quantization?: string;
  parameters?: string;
  context?: number;
  modified?: string;
  digest?: string;
  // Runtime info
  endpoint?: string;
  port?: number;
  pid?: number;
  memoryUsage?: number;
  gpuMemoryUsage?: number;
}

export interface LocalModelConfig {
  provider: LocalModelProvider;
  endpoint: string;
  apiKey?: string;
  defaultModel?: string;
  gpuLayers?: number;
  contextSize?: number;
  threads?: number;
}

// Training Types (AitherTrainer Integration)
export type TrainingStatus = 'pending' | 'preparing' | 'training' | 'validating' | 'completed' | 'failed' | 'cancelled';
export type DatasetSourceType = 'gemini-generated' | 'manual' | 'imported' | 'huggingface';

export interface TrainingDataset {
  id: string;
  name: string;
  sourceType: DatasetSourceType;
  rows: number;
  qualityScore?: number;
  validationStatus: 'pending' | 'passed' | 'failed';
  createdAt: string;
  generationModel?: string;
  generationPrompt?: string;
  stats?: {
    avgInstructionLength: number;
    avgResponseLength: number;
    uniqueTopics: number;
    complexityScore: number;
  };
}

export interface TrainingCheckpoint {
  id: string;
  epoch: number;
  step?: number;
  loss: number;
  validationLoss?: number;
  learningRate: number;
  timestamp: string;
  modelPath?: string;
}

export interface TrainingHyperparameters {
  epochs: number;
  batchSize: number;
  learningRate: number;
  warmupSteps: number;
  gradientAccumulationSteps?: number;
  weightDecay?: number;
  maxGradNorm?: number;
  loraRank?: number;
  loraAlpha?: number;
}

export interface TrainingRun {
  id: string;
  name: string;
  baseModel: string;
  datasetId: string;
  datasetName?: string;
  status: TrainingStatus;
  progress: number;
  startedAt?: string;
  completedAt?: string;
  estimatedTimeRemaining?: number;
  metrics: {
    currentEpoch: number;
    totalEpochs: number;
    currentStep?: number;
    totalSteps?: number;
    loss: number;
    validationLoss?: number;
    learningRate: number;
    tokensProcessed: number;
    samplesPerSecond?: number;
  };
  hyperparameters: TrainingHyperparameters;
  checkpoints: TrainingCheckpoint[];
  outputPath?: string;
  loraPath?: string;
  error?: string;
}

export interface SyntheticDataJob {
  id: string;
  name: string;
  model: string;
  targetRows: number;
  generatedRows: number;
  tokensConsumed: number;
  cost: number;
  status: 'pending' | 'running' | 'completed' | 'failed';
  prompt: string;
  createdAt: string;
  completedAt?: string;
  outputPath?: string;
}

// Training Dashboard State
export interface TrainingDashboardState {
  localModels: LocalModel[];
  modelConfig: LocalModelConfig;
  datasets: TrainingDataset[];
  trainingRuns: TrainingRun[];
  dataJobs: SyntheticDataJob[];
  benchmarks: BenchmarkRun[];
}

// Simple Dataset type for dashboard (used in Data Factory)
export interface Dataset {
  id: string;
  name: string;
  format: 'jsonl' | 'csv' | 'parquet' | 'json' | 'txt';
  recordCount?: number;
  sizeBytes?: number;
  path?: string;
  createdAt?: string;
}

// Infrastructure type alias for dashboard
export type Infrastructure = InfraState;

// Also update LocalModel status to include 'ready'
export type LocalModelStatusExtended = LocalModelStatus | 'ready';
