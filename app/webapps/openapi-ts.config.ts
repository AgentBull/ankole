export default {
  input: './openapi/console.json',
  output: {
    path: './console/api/generated'
  },
  plugins: ['@hey-api/client-fetch', '@tanstack/react-query']
}
