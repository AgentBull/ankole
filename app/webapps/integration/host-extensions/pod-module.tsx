import { useQuery } from '@tanstack/react-query'

export default function FixturePodModule() {
  const settings = useQuery({
    queryKey: ['fixture-settings'],
    queryFn: async () => {
      const response = await fetch('/api/v2/saas-pod/fixture-settings')
      if (!response.ok) throw new Error(`Fixture settings: ${response.status}`)
      return response.json()
    }
  })
  return <output data-testid="fixture-settings">{JSON.stringify(settings.data)}</output>
}
