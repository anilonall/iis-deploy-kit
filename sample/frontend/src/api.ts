// Base URL of the API, baked in at build time (no trailing slash).
// Production: build-package.ps1 sets VITE_API_BASE_URL=https://<domains.api>.
// Development: unset, so requests go to the Vite dev server, which proxies /api (vite.config.ts).
const baseUrl = (import.meta.env.VITE_API_BASE_URL ?? '').replace(/\/+$/, '')

export interface Todo {
  id: number
  title: string
  isDone: boolean
  createdAtUtc: string
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`, {
    ...init,
    headers: { 'Content-Type': 'application/json', ...init?.headers },
  })
  if (!response.ok) {
    throw new Error(`${init?.method ?? 'GET'} ${path} failed with HTTP ${response.status}`)
  }
  return (await response.json()) as T
}

export const getTodos = () => request<Todo[]>('/api/todos')

export const addTodo = (title: string) =>
  request<Todo>('/api/todos', { method: 'POST', body: JSON.stringify({ title }) })
