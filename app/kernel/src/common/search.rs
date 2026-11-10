use serde::Serialize;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ReciprocalRankFusionResult {
    pub id: String,
    pub score: f64,
}

#[derive(Debug)]
struct AccumulatedScore {
    score: f64,
    first_seen: usize,
}

pub fn reciprocal_rank_fusion(
    ranked_lists: &[Vec<String>],
    k: u64,
) -> Vec<ReciprocalRankFusionResult> {
    let mut accumulated = HashMap::<&str, AccumulatedScore>::new();
    let mut next_first_seen = 0;

    for ranked_list in ranked_lists {
        let mut seen_in_list = HashSet::<&str>::new();

        for (index, id) in ranked_list.iter().enumerate() {
            if !seen_in_list.insert(id.as_str()) {
                continue;
            }

            let rank = index + 1;
            let contribution = 1.0 / (k as f64 + rank as f64);

            match accumulated.entry(id.as_str()) {
                Entry::Occupied(mut entry) => {
                    entry.get_mut().score += contribution;
                }
                Entry::Vacant(entry) => {
                    entry.insert(AccumulatedScore {
                        score: contribution,
                        first_seen: next_first_seen,
                    });
                    next_first_seen += 1;
                }
            }
        }
    }

    let mut fused: Vec<_> = accumulated.into_iter().collect();
    fused.sort_by(|(_, left), (_, right)| {
        right
            .score
            .total_cmp(&left.score)
            .then_with(|| left.first_seen.cmp(&right.first_seen))
    });

    fused
        .into_iter()
        .map(|(id, accumulated)| ReciprocalRankFusionResult {
            id: id.to_owned(),
            score: accumulated.score,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(values: &[&[&str]]) -> Vec<Vec<String>> {
        values
            .iter()
            .map(|ranked_list| ranked_list.iter().map(|id| (*id).to_string()).collect())
            .collect()
    }

    #[test]
    fn empty_inputs_produce_no_results() {
        assert!(reciprocal_rank_fusion(&[], 60).is_empty());
        assert!(reciprocal_rank_fusion(&ids(&[&[], &[]]), 60).is_empty());
    }

    #[test]
    fn duplicate_ids_in_one_route_only_contribute_at_their_first_rank() {
        let fused = reciprocal_rank_fusion(&ids(&[&["a", "a", "b"]]), 60);

        assert_eq!(
            fused
                .iter()
                .map(|result| result.id.as_str())
                .collect::<Vec<_>>(),
            ["a", "b"]
        );
        assert!((fused[0].score - 1.0 / 61.0).abs() < f64::EPSILON);
        assert!((fused[1].score - 1.0 / 63.0).abs() < f64::EPSILON);
    }

    #[test]
    fn equal_scores_preserve_first_appearance_order() {
        let fused = reciprocal_rank_fusion(&ids(&[&["first"], &["second"], &["third"]]), 60);

        assert_eq!(
            fused
                .iter()
                .map(|result| result.id.as_str())
                .collect::<Vec<_>>(),
            ["first", "second", "third"]
        );
    }
}
