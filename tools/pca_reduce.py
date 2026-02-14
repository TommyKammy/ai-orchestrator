#!/usr/bin/env python3
"""
PCA Dimension Reduction Tool for Gemini Embeddings

Reduces 3072-dimensional Gemini embeddings to 1536 dimensions
using Principal Component Analysis (PCA).

Usage:
    # Fit PCA on collected embeddings
    python pca_reduce.py fit --samples 5000 --output pca_model.pkl
    
    # Transform a single embedding
    python pca_reduce.py transform --input "[0.1,0.2,...]" --model pca_model.pkl
    
    # Batch transform from file
    python pca_reduce.py transform --input-file embeddings.json --model pca_model.pkl --output reduced.json
"""

import argparse
import json
import pickle
import sys
from pathlib import Path
from typing import List, Union

import numpy as np
from sklearn.decomposition import PCA


class EmbeddingReducer:
    """PCA-based dimension reducer for embeddings."""
    
    def __init__(self, n_components: int = 1536):
        self.n_components = n_components
        self.pca = None
        self.fitted = False
    
    def fit(self, embeddings: np.ndarray) -> 'EmbeddingReducer':
        """
        Fit PCA on sample embeddings.
        
        Args:
            embeddings: Array of shape (n_samples, 3072)
            
        Returns:
            self for method chaining
        """
        if embeddings.shape[1] != 3072:
            raise ValueError(f"Expected 3072 dimensions, got {embeddings.shape[1]}")
        
        print(f"Fitting PCA on {embeddings.shape[0]} samples...")
        print(f"Reducing from {embeddings.shape[1]} to {self.n_components} dimensions")
        
        self.pca = PCA(n_components=self.n_components)
        self.pca.fit(embeddings)
        self.fitted = True
        
        # Print variance explained
        explained_var = np.sum(self.pca.explained_variance_ratio_)
        print(f"Explained variance: {explained_var:.4f} ({explained_var*100:.2f}%)")
        print(f"Model fitted successfully")
        
        return self
    
    def transform(self, embeddings: Union[np.ndarray, List]) -> np.ndarray:
        """
        Transform embeddings to lower dimension.
        
        Args:
            embeddings: Array of shape (n_samples, 3072) or list
            
        Returns:
            Reduced embeddings of shape (n_samples, 1536)
        """
        if not self.fitted:
            raise RuntimeError("Model not fitted. Call fit() first.")
        
        # Convert to numpy if needed
        if isinstance(embeddings, list):
            embeddings = np.array(embeddings)
        
        # Handle single embedding
        if embeddings.ndim == 1:
            embeddings = embeddings.reshape(1, -1)
        
        if embeddings.shape[1] != 3072:
            raise ValueError(f"Expected 3072 dimensions, got {embeddings.shape[1]}")
        
        return self.pca.transform(embeddings)
    
    def save(self, filepath: str):
        """Save fitted model to file."""
        if not self.fitted:
            raise RuntimeError("Cannot save unfitted model")
        
        model_data = {
            'pca': self.pca,
            'n_components': self.n_components,
            'fitted': self.fitted,
            'explained_variance_ratio_': self.pca.explained_variance_ratio_.tolist()
        }
        
        with open(filepath, 'wb') as f:
            pickle.dump(model_data, f)
        
        print(f"Model saved to {filepath}")
    
    @classmethod
    def load(cls, filepath: str) -> 'EmbeddingReducer':
        """Load fitted model from file."""
        with open(filepath, 'rb') as f:
            model_data = pickle.load(f)
        
        reducer = cls(n_components=model_data['n_components'])
        reducer.pca = model_data['pca']
        reducer.fitted = model_data['fitted']
        
        print(f"Model loaded from {filepath}")
        print(f"Explained variance: {np.sum(model_data['explained_variance_ratio_']):.4f}")
        
        return reducer


def generate_dummy_samples(n_samples: int = 1000) -> np.ndarray:
    """
    Generate dummy embedding samples for testing.
    In production, collect real Gemini embeddings.
    """
    print(f"Generating {n_samples} dummy samples for testing...")
    # Generate correlated random data to simulate embeddings
    np.random.seed(42)
    
    # Create some structure in the data (PCA works better with structure)
    base = np.random.randn(n_samples, 500)
    noise = np.random.randn(n_samples, 3072) * 0.1
    
    # Project to 3072 dimensions with structure
    projection = np.random.randn(500, 3072)
    embeddings = base @ projection + noise
    
    # Normalize (typical for embeddings)
    embeddings = embeddings / np.linalg.norm(embeddings, axis=1, keepdims=True)
    
    return embeddings


def fetch_samples_from_db(n_samples: int = 5000) -> np.ndarray:
    """
    Fetch embedding samples from PostgreSQL.
    Requires environment variables for DB connection.
    """
    try:
        import psycopg2
        import os
        
        conn = psycopg2.connect(
            host=os.getenv('DB_HOST', 'localhost'),
            port=os.getenv('DB_PORT', '5432'),
            database=os.getenv('DB_NAME', 'ai_memory'),
            user=os.getenv('DB_USER', 'ai_user'),
            password=os.getenv('DB_PASSWORD', 'password')
        )
        
        cur = conn.cursor()
        cur.execute(f"""
            SELECT embedding::text 
            FROM memory_vectors 
            ORDER BY created_at DESC 
            LIMIT {n_samples}
        """)
        
        rows = cur.fetchall()
        cur.close()
        conn.close()
        
        if len(rows) < 100:
            print(f"Warning: Only {len(rows)} samples in DB. Using dummy data.")
            return generate_dummy_samples(max(n_samples, 1000))
        
        # Parse vector strings
        embeddings = []
        for row in rows:
            # Parse "[0.1,0.2,...]" format
            vec_str = row[0].strip('[]')
            vec = [float(x) for x in vec_str.split(',')]
            embeddings.append(vec)
        
        print(f"Fetched {len(embeddings)} samples from database")
        return np.array(embeddings)
        
    except Exception as e:
        print(f"Database error: {e}")
        print("Falling back to dummy data...")
        return generate_dummy_samples(max(n_samples, 1000))


def compare_methods():
    """Compare PCA vs simple truncation quality."""
    print("\n=== Quality Comparison: PCA vs Truncation ===\n")
    
    # Generate test data
    samples = generate_dummy_samples(500)
    
    # Simple truncation
    truncated = samples[:, :1536]
    trunc_norm = np.linalg.norm(truncated, axis=1).mean()
    print(f"Truncation - Mean norm: {trunc_norm:.4f}")
    
    # PCA reduction
    reducer = EmbeddingReducer(n_components=1536)
    reducer.fit(samples)
    pca_reduced = reducer.transform(samples)
    pca_norm = np.linalg.norm(pca_reduced, axis=1).mean()
    print(f"PCA - Mean norm: {pca_norm:.4f}")
    print(f"PCA - Explained variance: {np.sum(reducer.pca.explained_variance_ratio_):.4f}")
    
    # Reconstruction quality
    reconstructed = reducer.pca.inverse_transform(pca_reduced)
    mse = np.mean((samples - reconstructed) ** 2)
    print(f"PCA - Reconstruction MSE: {mse:.6f}")
    
    print("\nPCA preserves more information but requires fitted model.")
    print("Truncation is simpler and faster but loses tail dimensions.")


def main():
    parser = argparse.ArgumentParser(
        description='PCA Dimension Reduction for Gemini Embeddings'
    )
    subparsers = parser.add_subparsers(dest='command', help='Command to run')
    
    # Fit command
    fit_parser = subparsers.add_parser('fit', help='Fit PCA model')
    fit_parser.add_argument('--samples', type=int, default=5000,
                          help='Number of samples to use (default: 5000)')
    fit_parser.add_argument('--source', choices=['db', 'dummy'], default='db',
                          help='Data source (default: db)')
    fit_parser.add_argument('--output', default='pca_model.pkl',
                          help='Output model file (default: pca_model.pkl)')
    fit_parser.add_argument('--components', type=int, default=1536,
                          help='Target dimensions (default: 1536)')
    
    # Transform command
    transform_parser = subparsers.add_parser('transform', help='Transform embeddings')
    transform_parser.add_argument('--model', default='pca_model.pkl',
                                help='Model file to load')
    transform_parser.add_argument('--input', type=str,
                                help='Input embedding as JSON string')
    transform_parser.add_argument('--input-file', type=str,
                                help='Input file with embeddings (JSON)')
    transform_parser.add_argument('--output', type=str,
                                help='Output file for reduced embeddings')
    
    # Compare command
    subparsers.add_parser('compare', help='Compare PCA vs truncation')
    
    args = parser.parse_args()
    
    if args.command == 'fit':
        # Fetch or generate samples
        if args.source == 'db':
            samples = fetch_samples_from_db(args.samples)
        else:
            samples = generate_dummy_samples(args.samples)
        
        # Fit model
        reducer = EmbeddingReducer(n_components=args.components)
        reducer.fit(samples)
        reducer.save(args.output)
        
        # Test transformation
        test_result = reducer.transform(samples[:1])
        print(f"\nTest transformation: {samples[:1].shape} -> {test_result.shape}")
        
    elif args.command == 'transform':
        # Load model
        reducer = EmbeddingReducer.load(args.model)
        
        # Get input
        if args.input:
            embedding = json.loads(args.input)
        elif args.input_file:
            with open(args.input_file, 'r') as f:
                data = json.load(f)
                embedding = data if isinstance(data, list) else data.get('embedding')
        else:
            print("Error: Provide --input or --input-file")
            sys.exit(1)
        
        # Transform
        result = reducer.transform(embedding)
        
        # Output
        output = {
            'original_dims': 3072,
            'reduced_dims': args.components if hasattr(args, 'components') else 1536,
            'reduced_embedding': result.tolist()[0] if result.shape[0] == 1 else result.tolist()
        }
        
        if args.output:
            with open(args.output, 'w') as f:
                json.dump(output, f, indent=2)
            print(f"Result saved to {args.output}")
        else:
            print(json.dumps(output, indent=2))
            
    elif args.command == 'compare':
        compare_methods()
        
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
