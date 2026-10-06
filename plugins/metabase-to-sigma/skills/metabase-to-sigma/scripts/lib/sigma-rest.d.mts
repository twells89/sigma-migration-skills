export interface SigmaResponse {
  status: number;
  ok: boolean;
  text: string;
  json: unknown;
}

export interface SigmaClient {
  base: string;
  api(method: string, path: string, body?: unknown): Promise<SigmaResponse>;
}

export function makeClient(workdir?: string): SigmaClient;
