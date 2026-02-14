#!/usr/bin/env python3
"""
Export PCA model to JSON format for n8n JavaScript usage

Converts sklearn PCA pickle to JSON with components and mean
for use in n8n Code nodes.

Usage:
    python export_pca_to_json.py --input pca_model.pkl --output pca_model.json
"""

import argparse
import json
import pickle
import sys


def export_pca_to_json(input_file: str, output_file: str):
    """Export PCA model components to JSON."""
    
    # Load pickle
    with open(input_file, 'rb') as f:
        model_data = pickle.load(f)
    
    pca = model_data['pca']
    
    # Extract components and mean
    export_data = {
        'n_components': int(model_data['n_components']),
        'fitted': model_data['fitted'],
        'explained_variance_ratio': model_data.get('explained_variance_ratio_', []),
        'mean': pca.mean_.tolist(),
        'components': pca.components_.tolist()
    }
    
    # Save JSON
    with open(output_file, 'w') as f:
        json.dump(export_data, f, indent=2)
    
    print(f"Exported PCA model to {output_file}")
    print(f"  Components shape: {pca.components_.shape}")
    print(f"  Mean shape: {pca.mean_.shape}")
    print(f"  Explained variance: {sum(export_data['explained_variance_ratio']):.4f}")


def main():
    parser = argparse.ArgumentParser(description='Export PCA to JSON')
    parser.add_argument('--input', required=True, help='Input pickle file')
    parser.add_argument('--output', required=True, help='Output JSON file')
    
    args = parser.parse_args()
    export_pca_to_json(args.input, args.output)


if __name__ == '__main__':
    main()
