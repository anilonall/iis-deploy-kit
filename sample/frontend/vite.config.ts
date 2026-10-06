import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    // Local development: the API runs on http://localhost:5080 (dotnet run). Requests stay
    // same-origin through this proxy, so no CORS setup is needed while developing.
    proxy: {
      '/api': 'http://localhost:5080',
    },
  },
})
