import os
import sys
import asyncio
import logging
import warnings
import argparse
import re
from rich.console import Console, Group
from rich.markdown import Markdown
from rich.panel import Panel
from rich.text import Text
from rich.live import Live
from rich.spinner import Spinner
from rich.theme import Theme
from rich.rule import Rule

# Prompt Toolkit
from prompt_toolkit import PromptSession
from prompt_toolkit.key_binding import KeyBindings
from prompt_toolkit.formatted_text import HTML
from prompt_toolkit.styles import Style as PromptStyle

from google.adk import Agent, Runner
from google.adk.apps import App
from google.genai import types
from google.adk.sessions import InMemorySessionService
from google.adk.artifacts import InMemoryArtifactService
from google.adk.auth.credential_service.in_memory_credential_service import InMemoryCredentialService

# Configure logging to suppress library warnings
if not sys.warnoptions:
 warnings.simplefilter("ignore")
warnings.filterwarnings("ignore", message=".*non-text parts.*")

logging.getLogger("google.genai").setLevel(logging.ERROR)
logging.getLogger("google.adk").setLevel(logging.ERROR)
logging.getLogger("absl").setLevel(logging.ERROR)

# Custom Theme
custom_theme = Theme({
 "info": "dim cyan",
 "warning": "bold magenta",
 "danger": "bold red",
 "user": "bold magenta",
 "agent": "bold cyan",
 "tool": "italic cyan"
})

console = Console(theme=custom_theme)

# Prompt Toolkit Style
prompt_style = PromptStyle.from_dict({
 'prompt': 'ansimagenta bold',
 'input': '#ffffff',
})

def create_keybindings():
 kb = KeyBindings()

 @kb.add('c-j') # Often corresponds to Ctrl+Enter
 @kb.add('escape', 'enter') # Backup
 def _(event):
 """Accept input (Submit)."""
 event.current_buffer.validate_and_handle()

 @kb.add('enter')
 def _(event):
 """Insert newline."""
 event.current_buffer.insert_text('\n')
 
 return kb

def strip_ansi(text):
 ansi_escape = re.compile(r'\x1B(?:[@-Z\-_]|[[0-?]*[ -/]*[@-~])')
 return ansi_escape.sub('', text)

def print_banner(model_name="gemini-2.5-flash"):
 title = Text()
 title.append("Aither", style="bold cyan")
 title.append("Zero", style="bold magenta")
 subtitle = Text("Automation Agent", style="dim white")
 
 grid_text = Text("Powered by ", style="dim white")
 grid_text.append(f"{model_name}", style="bold #4285F4")
 
 content = Text.assemble(title, "\n", subtitle, "\n\n", grid_text, justify="center")
 
 panel = Panel(
 content,
 border_style="bold cyan",
 padding=(1, 2),
 title="[bold magenta]v1.2[/]",
 subtitle="[italic dim]System Automation Interface[/]"
 )
 console.print(panel)
 console.print()

def create_agent(model_name="gemini-2.5-flash"):
 """Creates and configures the AitherZero Automation Agent."""
 try:
 from prompts import SYSTEM_INSTRUCTION
 from tools.aither_tools import aither_tools
 except ImportError:
 # Fallback for when running as package or different context
 from .prompts import SYSTEM_INSTRUCTION
 from .tools.aither_tools import aither_tools

 agent = Agent(
 name="AitherZeroAutomationAgent",
 model=model_name,
 instruction=SYSTEM_INSTRUCTION,
 tools=aither_tools
 )

 return agent

async def main():
 from dotenv import load_dotenv
 load_dotenv()
 
 parser = argparse.ArgumentParser(description="AitherZero Automation Agent")
 parser.add_argument("--model", type=str, default="gemini-2.5-flash", 
 help="Model to use (e.g., gemini-2.5-pro)")
 args, unknown = parser.parse_known_args()
 model_name = args.model

 if not os.getenv("GOOGLE_API_KEY") and not os.getenv("GEMINI_API_KEY"):
 console.print("[danger]Error: GOOGLE_API_KEY or GEMINI_API_KEY not found.[/]")
 return

 print_banner(model_name)

 try:
 with console.status(f"[bold green]Initializing Agent with {model_name}...[/]", spinner="dots"):
 agent = create_agent(model_name)
 
 session_service = InMemorySessionService()
 artifact_service = InMemoryArtifactService()
 credential_service = InMemoryCredentialService()
 
 app = App(name="agents", root_agent=agent)

 runner = Runner(
 app=app,
 session_service=session_service,
 artifact_service=artifact_service,
 credential_service=credential_service
 )
 
 user_id = "user"
 session = await runner.session_service.create_session(app_name=app.name, user_id=user_id)
 session_id = session.id

 console.print(f"[info]Session created: {session_id}[/]")
 console.print("[bold green]>>> Ready. Use Arrow keys to move. Enter for newline. Esc+Enter to submit.[/]\n")
 
 # Setup Prompt Session
 session = PromptSession(
 key_bindings=create_keybindings(),
 multiline=True,
 style=prompt_style
 )
 
 while True:
 try:
 # Separator
 console.print(Rule(style="dim cyan"))
 
 # Advanced Input
 user_input = await session.prompt_async(HTML("<prompt>Aither ></prompt> "))
 
 if not user_input.strip():
 continue

 if user_input.lower() in ["exit", "quit"]:
 console.print("\n[warning]Shutting down agent...[/]")
 break

 # Process
 content = types.Content(role='user', parts=[types.Part(text=user_input)])
 
 full_response = ""
 active_tool = None
 
 # We use one Live display for the whole turn
 with Live(Spinner("dots", text="[dim]Thinking...[/]", style="magenta"), refresh_per_second=12, transient=False) as live:
 async for event in runner.run_async(user_id=user_id, session_id=session_id, new_message=content):
 
 if event.content and event.content.parts:
 for part in event.content.parts:
 # Handle Tool Execution
 if part.function_call:
 active_tool = part.function_call.name
 
 # Render: Text (if any) + Tool Spinner
 renderables = 
 if full_response:
 clean_text = strip_ansi(full_response)
 renderables.append(Panel(Markdown(clean_text), title="[agent]AitherZero[/]", border_style="cyan", title_align="left"))
 
 renderables.append(Spinner("clock", text=f"[tool]Executing {active_tool}...[/]", style="cyan"))
 live.update(Group(*renderables))
 continue
 
 # Handle Text Response
 if part.text:
 active_tool = None # Tool finished if we are getting text
 
 # Typewriter effect
 for char in part.text:
 full_response += char
 if len(full_response) % 2 == 0: # Optimization
 renderables = 
 clean_text = strip_ansi(full_response)
 renderables.append(Panel(Markdown(clean_text + ""), title="[agent]AitherZero[/]", border_style="cyan", title_align="left"))
 live.update(Group(*renderables))
 await asyncio.sleep(0.002) 
 
 # Ensure final update for the chunk
 renderables = 
 clean_text = strip_ansi(full_response)
 renderables.append(Panel(Markdown(clean_text), title="[agent]AitherZero[/]", border_style="cyan", title_align="left"))
 live.update(Group(*renderables))

 except KeyboardInterrupt:
 console.print("\n[warning]Interrupted.[/]")
 break
 except Exception as e:
 console.print(f"\n[danger]Error during chat: {e}[/]")

 except Exception as e:
 console.print(f"[danger]Failed to initialize agent: {e}[/]")

if __name__ == "__main__":
 try:
 asyncio.run(main())
 except KeyboardInterrupt:
 pass