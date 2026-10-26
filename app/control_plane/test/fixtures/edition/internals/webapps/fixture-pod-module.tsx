import { useQuery } from '@tanstack/react-query'
import { fixturePodSettings } from './pod-api/generated/sdk.gen'

export default function FixturePodModule() {
  const query = useQuery({
    queryKey: ['fixture-settings'],
    queryFn: () => fixturePodSettings()
  })
  return <output data-testid="fixture-settings">{JSON.stringify(query.data)}</output>
}
