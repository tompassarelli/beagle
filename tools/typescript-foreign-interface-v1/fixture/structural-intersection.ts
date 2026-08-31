interface RouteObservationEvidence {
  observedAt: string;
  pressure?: string;
}

type OptionalEvidence = Partial<RouteObservationEvidence>;

export function refine(
  entry: RouteObservationEvidence & { pressure: string },
): {
  entry: RouteObservationEvidence & { pressure: string };
  label?: string;
} {
  return { entry };
}

export function preserveTypedBoundaries(
  optional: OptionalEvidence,
  uncertainty: unknown,
  opaque: object,
): number {
  return 0;
}
