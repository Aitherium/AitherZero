import argparse
import asyncio
import json
import logging
import os
import shlex
import sys
import warnings
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import httpx
from dotenv import load_dotenv
from prompt_toolkit import PromptSession
from prompt_toolkit.formatted_text import HTML
from prompt_toolkit.key_binding import KeyBindings
from prompt_toolkit.styles import Style as PromptStyle
from rich.console import Console
from rich.markdown import Markdown
from rich.panel import Panel
from rich.rule import Rule
from rich.table import Table
from rich.text import Text
from rich.theme import Theme

try:
	from prompts import SYSTEM_INSTRUCTION
	from tools.aither_tools import (
		execute_agent_workflow,
		execute_aither_playbook,
		execute_aither_script,
		get_aither_config,
		list_automation_scripts,
		list_mcp_servers,
		list_mcp_tools,
		list_playbooks,
		manage_mcp_server,
		call_mcp_tool,
		set_aither_config,
	)
except ImportError:
	from .prompts import SYSTEM_INSTRUCTION
	from .tools.aither_tools import (
		execute_agent_workflow,
		execute_aither_playbook,
		execute_aither_script,
		get_aither_config,
		list_automation_scripts,
		list_mcp_servers,
		list_mcp_tools,
		list_playbooks,
		manage_mcp_server,
		call_mcp_tool,
		set_aither_config,
	)

if not sys.warnoptions:
	warnings.simplefilter("ignore")

logging.getLogger("httpx").setLevel(logging.WARNING)

custom_theme = Theme(
	{
		"info": "dim cyan",
		"warning": "bold magenta",
		"danger": "bold red",
		"user": "bold magenta",
		"agent": "bold cyan",
		"tool": "italic cyan",
	}
)

console = Console(theme=custom_theme)
prompt_style = PromptStyle.from_dict({"prompt": "ansimagenta bold", "input": "#ffffff"})


@dataclass
class BackendConfig:
	backend: str
	model: str
	temperature: float
	timeout: float
	ollama_host: str
	vllm_base_url: str
	vllm_api_key: Optional[str]

	@property
	def display_backend(self) -> str:
		return self.backend.upper()


def normalize_base_url(url: str) -> str:
	return url.rstrip("/")


def create_keybindings() -> KeyBindings:
	bindings = KeyBindings()

	@bindings.add("c-j")
	@bindings.add("escape", "enter")
	def _(event):
		event.current_buffer.validate_and_handle()

	@bindings.add("enter")
	def _(event):
		event.current_buffer.insert_text("\n")

	return bindings


def print_banner(config: BackendConfig) -> None:
	title = Text()
	title.append("Aither", style="bold cyan")
	title.append("Zero", style="bold magenta")
	subtitle = Text("Local Automation Agent", style="dim white")
	footer = Text("Backend: ", style="dim white")
	footer.append(config.display_backend, style="bold cyan")
	footer.append("  Model: ", style="dim white")
	footer.append(config.model, style="bold #4285F4")

	panel = Panel(
		Text.assemble(title, "\n", subtitle, "\n\n", footer, justify="center"),
		border_style="bold cyan",
		padding=(1, 2),
		title="[bold magenta]v2.0[/]",
		subtitle="[italic dim]Local-first Ollama / vLLM interface[/]",
	)
	console.print(panel)
	console.print("[info]Commands:[/] `/help`, `/backend`, `/scripts`, `/script`, `/playbooks`, `/playbook`, `/config`, `/set-config`, `/mcp-*`, `/workflow`, `quit`")
	console.print()


def build_backend_config(args: argparse.Namespace) -> BackendConfig:
	backend = (args.backend or os.getenv("AGENT_BACKEND") or "auto").lower()
	model = args.model or os.getenv("AGENT_MODEL") or os.getenv("OLLAMA_MODEL") or os.getenv("VLLM_MODEL") or "llama3.1:8b"
	temperature = args.temperature if args.temperature is not None else float(os.getenv("AGENT_TEMPERATURE", "0.2"))
	timeout = args.timeout if args.timeout is not None else float(os.getenv("AGENT_TIMEOUT", "120"))
	ollama_host = normalize_base_url(os.getenv("OLLAMA_HOST", "http://localhost:11434"))
	vllm_base_url = normalize_base_url(os.getenv("VLLM_BASE_URL", "http://localhost:8000/v1"))
	vllm_api_key = os.getenv("VLLM_API_KEY") or os.getenv("OPENAI_API_KEY")
	return BackendConfig(backend, model, temperature, timeout, ollama_host, vllm_base_url, vllm_api_key)


class LocalLLMClient:
	def __init__(self, config: BackendConfig):
		self.config = config

	async def chat(self, messages: List[Dict[str, str]]) -> str:
		backend = self.config.backend
		if backend == "auto":
			backend = await self._detect_backend()
		if backend == "ollama":
			return await self._chat_ollama(messages)
		if backend == "vllm":
			return await self._chat_vllm(messages)
		raise RuntimeError(f"Unsupported backend: {backend}")

	async def _detect_backend(self) -> str:
		async with httpx.AsyncClient(timeout=5.0) as client:
			try:
				response = await client.get(f"{self.config.ollama_host}/api/tags")
				if response.is_success:
					return "ollama"
			except httpx.HTTPError:
				pass

			vllm_models_url = f"{self.config.vllm_base_url}/models"
			try:
				response = await client.get(vllm_models_url, headers=self._vllm_headers())
				if response.is_success:
					return "vllm"
			except httpx.HTTPError:
				pass

		raise RuntimeError(
			"No local backend detected. Start Ollama or a vLLM server, or set AGENT_BACKEND explicitly."
		)

	async def _chat_ollama(self, messages: List[Dict[str, str]]) -> str:
		payload = {
			"model": self.config.model,
			"messages": messages,
			"stream": False,
			"options": {"temperature": self.config.temperature},
		}
		async with httpx.AsyncClient(timeout=self.config.timeout) as client:
			response = await client.post(f"{self.config.ollama_host}/api/chat", json=payload)
			response.raise_for_status()
			data = response.json()
			return data.get("message", {}).get("content", "").strip()

	async def _chat_vllm(self, messages: List[Dict[str, str]]) -> str:
		payload = {
			"model": self.config.model,
			"messages": messages,
			"temperature": self.config.temperature,
		}
		async with httpx.AsyncClient(timeout=self.config.timeout) as client:
			response = await client.post(
				f"{self.config.vllm_base_url}/chat/completions",
				headers=self._vllm_headers(),
				json=payload,
			)
			response.raise_for_status()
			data = response.json()
			return data["choices"][0]["message"]["content"].strip()

	def _vllm_headers(self) -> Dict[str, str]:
		headers = {"Content-Type": "application/json"}
		if self.config.vllm_api_key:
			headers["Authorization"] = f"Bearer {self.config.vllm_api_key}"
		return headers


def print_response(title: str, content: str, style: str = "cyan") -> None:
	body = content.strip() or "(empty response)"
	console.print(Panel(Markdown(body), title=title, border_style=style, title_align="left"))


def print_backend_table(config: BackendConfig) -> None:
	table = Table(title="Backend Configuration")
	table.add_column("Setting", style="cyan")
	table.add_column("Value", style="white")
	table.add_row("Backend", config.backend)
	table.add_row("Model", config.model)
	table.add_row("Ollama Host", config.ollama_host)
	table.add_row("vLLM Base URL", config.vllm_base_url)
	table.add_row("Temperature", str(config.temperature))
	table.add_row("Timeout", str(config.timeout))
	console.print(table)


def parse_json_arg(raw: str) -> Optional[Dict[str, Any]]:
	if not raw:
		return None
	return json.loads(raw)


async def handle_command(user_input: str, config: BackendConfig, messages: List[Dict[str, str]]) -> bool:
	parts = shlex.split(user_input)
	command = parts[0].lower()

	if command in {"/quit", "/exit"}:
		console.print("[warning]Shutting down agent...[/]")
		return False

	if command == "/help":
		console.print(
			Panel(
				"\n".join(
					[
						"/backend - show active backend settings",
						"/clear - clear conversation history",
						"/scripts [filter] - list automation scripts",
						"/script <name_or_id> [json] - run a script",
						"/playbooks [filter] - list playbooks",
						"/playbook <name> [json] - run a playbook",
						"/config [section] [key] - inspect config",
						"/set-config <section> <key> <value> [scope] - update config",
						"/mcp-servers - list MCP servers",
						"/mcp-tools <server> - list tools for a server",
						"/mcp-call <server> <tool> [json] - call an MCP tool",
						"/mcp-install - build/install local MCP server",
						"/workflow <name> [json] - run an agent workflow",
						"quit - exit the session",
					]
				),
				title="[tool]Slash Commands[/]",
				border_style="magenta",
			)
		)
		return True

	if command == "/backend":
		print_backend_table(config)
		return True

	if command == "/clear":
		del messages[1:]
		console.print("[info]Conversation history cleared.[/]")
		return True

	if command == "/scripts":
		output = list_automation_scripts(parts[1] if len(parts) > 1 else "")
		print_response("[tool]Scripts[/]", f"```json\n{output}\n```", "magenta")
		return True

	if command == "/script":
		if len(parts) < 2:
			console.print("[danger]Usage: /script <name_or_id> [json-params][/]")
			return True
		params = parse_json_arg(parts[2]) if len(parts) > 2 else None
		output = execute_aither_script(parts[1], params)
		print_response("[tool]Script Result[/]", f"```text\n{output}\n```", "magenta")
		return True

	if command == "/playbooks":
		output = list_playbooks(parts[1] if len(parts) > 1 else "")
		print_response("[tool]Playbooks[/]", f"```json\n{output}\n```", "magenta")
		return True

	if command == "/playbook":
		if len(parts) < 2:
			console.print("[danger]Usage: /playbook <name> [json-vars][/]")
			return True
		variables = parse_json_arg(parts[2]) if len(parts) > 2 else None
		output = execute_aither_playbook(parts[1], variables)
		print_response("[tool]Playbook Result[/]", f"```text\n{output}\n```", "magenta")
		return True

	if command == "/config":
		section = parts[1] if len(parts) > 1 else None
		key = parts[2] if len(parts) > 2 else None
		output = get_aither_config(section, key)
		print_response("[tool]Configuration[/]", f"```json\n{output}\n```", "magenta")
		return True

	if command == "/set-config":
		if len(parts) < 4:
			console.print("[danger]Usage: /set-config <section> <key> <value> [scope][/]")
			return True
		scope = parts[4] if len(parts) > 4 else "local"
		output = set_aither_config(parts[1], parts[2], parts[3], scope)
		print_response("[tool]Config Update[/]", f"```text\n{output}\n```", "magenta")
		return True

	if command == "/mcp-install":
		output = manage_mcp_server("install")
		print_response("[tool]MCP Install[/]", f"```text\n{output}\n```", "magenta")
		return True

	if command == "/mcp-servers":
		output = await list_mcp_servers()
		print_response("[tool]MCP Servers[/]", f"```json\n{output}\n```", "magenta")
		return True

	if command == "/mcp-tools":
		if len(parts) < 2:
			console.print("[danger]Usage: /mcp-tools <server>[/]")
			return True
		output = await list_mcp_tools(parts[1])
		print_response("[tool]MCP Tools[/]", f"```json\n{output}\n```", "magenta")
		return True

	if command == "/mcp-call":
		if len(parts) < 3:
			console.print("[danger]Usage: /mcp-call <server> <tool> [json-args][/]")
			return True
		arguments = parse_json_arg(parts[3]) if len(parts) > 3 else None
		output = await call_mcp_tool(parts[1], parts[2], arguments)
		print_response("[tool]MCP Result[/]", f"```text\n{output}\n```", "magenta")
		return True

	if command == "/workflow":
		if len(parts) < 2:
			console.print("[danger]Usage: /workflow <name> [json-vars][/]")
			return True
		variables = parse_json_arg(parts[2]) if len(parts) > 2 else None
		output = await execute_agent_workflow(parts[1], variables)
		print_response("[tool]Workflow Result[/]", f"```text\n{output}\n```", "magenta")
		return True

	console.print("[danger]Unknown command. Use /help to see what is available.[/]")
	return True


async def chat_loop(config: BackendConfig) -> None:
	client = LocalLLMClient(config)
	messages: List[Dict[str, str]] = [{"role": "system", "content": SYSTEM_INSTRUCTION}]
	session = PromptSession(key_bindings=create_keybindings(), multiline=True, style=prompt_style)

	while True:
		try:
			console.print(Rule(style="dim cyan"))
			user_input = await session.prompt_async(HTML("<prompt>Aither ></prompt> "))
			if not user_input.strip():
				continue

			if user_input.strip().lower() in {"quit", "exit"}:
				console.print("[warning]Shutting down agent...[/]")
				return

			if user_input.startswith("/"):
				should_continue = await handle_command(user_input, config, messages)
				if not should_continue:
					return
				continue

			messages.append({"role": "user", "content": user_input})
			with console.status(f"[bold green]Querying {config.display_backend} backend...[/]", spinner="dots"):
				response = await client.chat(messages)
			messages.append({"role": "assistant", "content": response})
			print_response("[agent]AitherZero[/]", response)
		except KeyboardInterrupt:
			console.print("\n[warning]Interrupted.[/]")
			return
		except json.JSONDecodeError as exc:
			console.print(f"[danger]Invalid JSON arguments: {exc}[/]")
		except httpx.HTTPError as exc:
			console.print(f"[danger]Backend request failed: {exc}[/]")
		except Exception as exc:
			console.print(f"[danger]Error during chat: {exc}[/]")


async def main() -> None:
	load_dotenv()
	parser = argparse.ArgumentParser(description="AitherZero local automation agent")
	parser.add_argument("--backend", choices=["auto", "ollama", "vllm"], default=None)
	parser.add_argument("--model", type=str, default=None)
	parser.add_argument("--temperature", type=float, default=None)
	parser.add_argument("--timeout", type=float, default=None)
	args = parser.parse_args()
	config = build_backend_config(args)
	print_banner(config)
	await chat_loop(config)


if __name__ == "__main__":
	try:
		asyncio.run(main())
	except KeyboardInterrupt:
		pass