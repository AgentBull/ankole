import { GardState } from '../core/state'

export const knowledgeFacet = GardState.Facet.define<boolean, boolean>({ combine: values => values.some(Boolean) })
export const isKnowledge = (state: GardState) => state.facet(knowledgeFacet)
