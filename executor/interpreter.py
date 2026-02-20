"""
Code Interpreter with rich output support
Phase 3: Visualization & Advanced Features

Provides E2B-style code interpretation with support for:
- Text output
- Error messages with stack traces
- Charts and visualizations (matplotlib, plotly)
- HTML output
- JSON data
- Images
"""

import base64
import json
import logging
from typing import Dict, List, Optional, Any, Union
from dataclasses import dataclass, field, asdict
from enum import Enum

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class ArtifactType(Enum):
    """Types of artifacts that can be produced by code execution."""
    TEXT = "text"
    JSON = "json"
    HTML = "html"
    IMAGE_PNG = "image/png"
    IMAGE_JPEG = "image/jpeg"
    IMAGE_SVG = "image/svg+xml"
    CHART = "chart"
    ERROR = "error"


@dataclass
class Artifact:
    """Represents an artifact produced by code execution."""
    type: str
    name: str
    content: Any
    metadata: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert artifact to dictionary."""
        return {
            "type": self.type,
            "name": self.name,
            "content": self.content,
            "metadata": self.metadata
        }


@dataclass
class ExecutionResult:
    """Complete result of code execution."""
    status: str
    stdout: str
    stderr: str
    exit_code: int
    execution_time: float
    artifacts: List[Artifact] = field(default_factory=list)
    error_message: Optional[str] = None
    error_traceback: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert result to dictionary."""
        return {
            "status": self.status,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "exit_code": self.exit_code,
            "execution_time": self.execution_time,
            "artifacts": [a.to_dict() for a in self.artifacts],
            "error_message": self.error_message,
            "error_traceback": self.error_traceback
        }


class CodeInterpreter:
    """
    E2B-style code interpreter with rich output support.
    
    Features:
    - Execute code and capture rich outputs
    - Extract matplotlib charts
    - Handle plotly visualizations
    - Support HTML output
    - Format errors with tracebacks
    - Generate artifact metadata
    """
    
    def __init__(self, sandbox):
        """
        Initialize interpreter.
        
        Args:
            sandbox: CodeSandbox instance
        """
        self.sandbox = sandbox
    
    def run(
        self,
        code: str,
        language: str = "python",
        files: Optional[Dict[str, str]] = None,
        extract_artifacts: bool = True
    ) -> ExecutionResult:
        """
        Execute code and return rich result.
        
        Args:
            code: Code to execute
            language: Programming language
            files: Files to upload before execution
            extract_artifacts: Whether to extract visualizations
        
        Returns:
            ExecutionResult with artifacts
        """
        import time
        start_time = time.time()
        
        # Wrap code to capture matplotlib outputs
        if extract_artifacts and language == "python":
            code = self._wrap_matplotlib_code(code)
        
        # Execute code
        result = self.sandbox.run_code(code, language, files)
        
        execution_time = time.time() - start_time
        
        # Parse result
        if result['status'] == 'error' and result['exit_code'] != 0:
            return self._parse_error_result(result, execution_time)
        
        # Extract artifacts
        artifacts = []
        if extract_artifacts:
            artifacts = self._extract_artifacts()
        
        return ExecutionResult(
            status="success" if result['exit_code'] == 0 else "error",
            stdout=result.get('stdout', ''),
            stderr=result.get('stderr', ''),
            exit_code=result['exit_code'],
            execution_time=execution_time,
            artifacts=artifacts
        )
    
    def _wrap_matplotlib_code(self, code: str) -> str:
        """
        Wrap user code to capture matplotlib outputs.
        
        Args:
            code: Original code
        
        Returns:
            Wrapped code
        """
        wrapper = '''
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import io
import base64
import json
import os

# Ensure output directory exists
os.makedirs('/tmp/output', exist_ok=True)

# Store original show
_original_show = plt.show

def _capture_show(*args, **kwargs):
    """Capture plot instead of displaying."""
    buf = io.BytesIO()
    plt.savefig(buf, format='png', dpi=100, bbox_inches='tight')
    buf.seek(0)
    img_data = base64.b64encode(buf.read()).decode()
    
    # Save metadata
    fig_num = len(plt.get_fignums())
    with open(f'/tmp/output/plot_{fig_num}.json', 'w') as f:
        json.dump({"type": "image/png", "data": img_data}, f)
    
    plt.close()

plt.show = _capture_show

# Execute user code
''' + code + '''

# Capture any remaining plots
if plt.get_fignums():
    for i, fig_num in enumerate(plt.get_fignums()):
        plt.figure(fig_num)
        buf = io.BytesIO()
        plt.savefig(buf, format='png', dpi=100, bbox_inches='tight')
        buf.seek(0)
        img_data = base64.b64encode(buf.read()).decode()
        
        with open(f'/tmp/output/plot_{i}.json', 'w') as f:
            json.dump({"type": "image/png", "data": img_data}, f)
        
        plt.close(fig_num)
'''
        return wrapper
    
    def _extract_artifacts(self) -> List[Artifact]:
        """
        Extract artifacts from sandbox.
        
        Returns:
            List of artifacts
        """
        artifacts = []
        
        try:
            # Check for matplotlib outputs
            output_dir = "/tmp/output"
            result = self.sandbox.container.exec_run(
                ["ls", "-1", output_dir],
                user="sandbox"
            )
            
            if result.exit_code == 0 and result.output:
                files = result.output[0].decode('utf-8').strip().split('\n')
                
                for filename in files:
                    if filename.endswith('.json'):
                        # Read artifact metadata
                        file_content = self.sandbox.read_file(f"{output_dir}/{filename}")
                        if file_content:
                            try:
                                data = json.loads(file_content)
                                artifact = Artifact(
                                    type=data.get('type', 'text'),
                                    name=filename.replace('.json', ''),
                                    content=data.get('data', ''),
                                    metadata={"source": "matplotlib"}
                                )
                                artifacts.append(artifact)
                            except json.JSONDecodeError:
                                pass
                    
                    elif filename.endswith(('.png', '.jpg', '.jpeg', '.svg')):
                        # Read binary image
                        content = self.sandbox.read_file(f"{output_dir}/{filename}")
                        if content:
                            img_type = "image/png" if filename.endswith('.png') else \
                                      "image/jpeg" if filename.endswith(('.jpg', '.jpeg')) else \
                                      "image/svg+xml"
                            
                            artifact = Artifact(
                                type=img_type,
                                name=filename,
                                content=content,
                                metadata={"filename": filename}
                            )
                            artifacts.append(artifact)
        
        except Exception as e:
            logger.error(f"Failed to extract artifacts: {e}")
        
        return artifacts
    
    def _parse_error_result(self, result: Dict, execution_time: float) -> ExecutionResult:
        """
        Parse error result and extract traceback.
        
        Args:
            result: Raw execution result
            execution_time: Execution time
        
        Returns:
            ExecutionResult with error details
        """
        stderr = result.get('stderr', '')
        
        # Parse Python traceback
        error_message = stderr
        error_traceback = None
        
        if 'Traceback (most recent call last):' in stderr:
            parts = stderr.split('Traceback (most recent call last):')
            if len(parts) > 1:
                error_traceback = 'Traceback (most recent call last):' + parts[1]
                # Last line is usually the error message
                lines = error_traceback.strip().split('\n')
                error_message = lines[-1] if lines else stderr
        
        # Create error artifact
        error_artifact = Artifact(
            type="error",
            name="execution_error",
            content={
                "message": error_message,
                "traceback": error_traceback
            },
            metadata={"exit_code": result['exit_code']}
        )
        
        return ExecutionResult(
            status="error",
            stdout=result.get('stdout', ''),
            stderr=stderr,
            exit_code=result['exit_code'],
            execution_time=execution_time,
            artifacts=[error_artifact],
            error_message=error_message,
            error_traceback=error_traceback
        )
    
    def execute_plotly(
        self,
        code: str,
        files: Optional[Dict[str, str]] = None
    ) -> ExecutionResult:
        """
        Execute code with Plotly visualization support.
        
        Args:
            code: Code that generates plotly figures
            files: Files to upload
        
        Returns:
            ExecutionResult with plotly artifacts
        """
        # Wrap code to export plotly as JSON
        wrapped_code = '''
import plotly.graph_objects as go
import plotly.express as px
import json
import os

os.makedirs('/tmp/output', exist_ok=True)

# Store original show methods
_fig_original_show = go.Figure.show

def _export_plotly_json(fig, filename='plotly_chart.json'):
    """Export plotly figure as JSON."""
    json_str = fig.to_json()
    with open(f'/tmp/output/{filename}', 'w') as f:
        f.write(json_str)
    return json_str

# Monkey patch to capture figures
_captured_figures = []

def _captured_show(self, *args, **kwargs):
    _captured_figures.append(self)
    filename = f'plotly_chart_{len(_captured_figures)}.json'
    _export_plotly_json(self, filename)

go.Figure.show = _captured_show

# Execute user code
''' + code + '''

# Export any remaining figures
for i, fig in enumerate(_captured_figures):
    filename = f'plotly_chart_{i}.json'
    _export_plotly_json(fig, filename)
'''
        
        result = self.run(wrapped_code, files=files)
        
        # Convert plotly JSON artifacts
        for artifact in result.artifacts:
            if 'plotly' in artifact.name:
                artifact.type = "chart"
                artifact.metadata["library"] = "plotly"
        
        return result


def format_result_for_display(result: ExecutionResult) -> str:
    """
    Format execution result for display.
    
    Args:
        result: Execution result
    
    Returns:
        Formatted string
    """
    lines = []
    
    lines.append(f"Status: {result.status}")
    lines.append(f"Execution Time: {result.execution_time:.3f}s")
    lines.append(f"Exit Code: {result.exit_code}")
    lines.append("")
    
    if result.stdout:
        lines.append("STDOUT:")
        lines.append(result.stdout)
        lines.append("")
    
    if result.stderr:
        lines.append("STDERR:")
        lines.append(result.stderr)
        lines.append("")
    
    if result.artifacts:
        lines.append(f"Artifacts ({len(result.artifacts)}):")
        for artifact in result.artifacts:
            lines.append(f"  - {artifact.name} ({artifact.type})")
    
    return "\n".join(lines)


# Convenience function
def run_code(
    sandbox,
    code: str,
    language: str = "python",
    files: Optional[Dict[str, str]] = None,
    extract_artifacts: bool = True
) -> ExecutionResult:
    """
    Convenience function to run code with interpreter.
    
    Args:
        sandbox: CodeSandbox instance
        code: Code to execute
        language: Programming language
        files: Files to upload
        extract_artifacts: Whether to extract artifacts
    
    Returns:
        ExecutionResult
    """
    interpreter = CodeInterpreter(sandbox)
    return interpreter.run(code, language, files, extract_artifacts)
