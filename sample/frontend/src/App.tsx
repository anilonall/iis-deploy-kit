import { useEffect, useState, type FormEvent } from 'react'
import { addTodo, getTodos, type Todo } from './api'

export default function App() {
  const [todos, setTodos] = useState<Todo[]>([])
  const [title, setTitle] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    getTodos()
      .then(setTodos)
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)))
  }, [])

  async function onSubmit(event: FormEvent) {
    event.preventDefault()
    const trimmed = title.trim()
    if (!trimmed) return
    setBusy(true)
    setError(null)
    try {
      const created = await addTodo(trimmed)
      setTodos((current) => [created, ...current])
      setTitle('')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <main>
      <h1>Todos</h1>
      <form onSubmit={onSubmit}>
        <input
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          placeholder="What needs to be done?"
          maxLength={200}
          aria-label="New todo"
        />
        <button type="submit" disabled={busy || !title.trim()}>
          Add
        </button>
      </form>
      {error && <p role="alert" className="error">{error}</p>}
      <ul>
        {todos.map((todo) => (
          <li key={todo.id}>{todo.title}</li>
        ))}
      </ul>
      {todos.length === 0 && !error && <p className="muted">Nothing here yet.</p>}
    </main>
  )
}
