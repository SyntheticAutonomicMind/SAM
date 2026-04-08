# SAM Tools Reference

**What SAM can do autonomously with its built-in tools**

---

## Overview

SAM has 8 built-in tools that the AI uses to take action on your behalf. When you ask SAM to do something - read a file, search the web, create a document, calculate a mortgage payment - it selects the right tool and executes it automatically.

You see what SAM is doing in real time through tool cards that appear in the conversation, showing the operation, parameters, and results.

---

## How Tools Work

1. You describe what you want
2. The AI decides which tool(s) to use
3. SAM executes the tool and shows you a status card
4. The AI reads the result and responds (or takes the next action)

For complex tasks, SAM chains multiple tools together. It might search the web, read several pages, analyze the content, and write a summary - all in one flow.

### Multi-Step Tasks

When a task requires multiple steps, SAM creates a todo list to track progress:

1. Breaks the task into steps
2. Marks each step in-progress as it works
3. Marks steps complete as they finish
4. Reports results when done

If something goes wrong, SAM adjusts its approach and retries rather than giving up.

---

## Tool Reference

### File Operations

**What it does:** Read, write, search, and manage files on your Mac.

#### Reading Files

| Operation | Description | Example Use |
|-----------|-------------|------------|
| **Read file** | Read file content (full or partial) | "Read the first 50 lines of config.json" |
| **List directory** | List files and folders | "Show me what's in my project folder" |
| **Check errors** | Find compilation/lint errors | "Are there any errors in this Swift file?" |

#### Searching Files

| Operation | Description | Example Use |
|-----------|-------------|------------|
| **File search** | Find files by name pattern | "Find all .swift files in the project" |
| **Grep search** | Search file contents (text or regex) | "Find everywhere that uses 'apiKey'" |
| **Semantic search** | Find files by meaning | "Find the file that handles authentication" |
| **Code usages** | Find all references to a symbol | "Where is `loadModel()` called?" |

#### Writing Files

| Operation | Description | Example Use |
|-----------|-------------|------------|
| **Create file** | Create a new file | "Create a README.md with project info" |
| **Replace string** | Find and replace text | "Change all 'http://' to 'https://'" |
| **Multi-replace** | Batch replacements across files | "Update the version number in all config files" |
| **Insert edit** | Insert content at a location | "Add a new function after line 50" |
| **Rename file** | Rename or move a file | "Rename output.txt to results.txt" |
| **Delete file** | Delete a file or folder | "Remove the old backup directory" |
| **Create directory** | Create a folder | "Create a 'reports' directory" |

#### Authorization

Files inside your SAM working directory (`~/SAM/`) are accessed freely. Files outside require your explicit permission.

---

### Web Operations

**What it does:** Search the web, fetch pages, scrape content, and conduct research.

| Operation | Description | Best For |
|-----------|-------------|---------|
| **Research** | Multi-source research with synthesis | "Research the best practices for Swift concurrency" |
| **Retrieve** | Recall previously stored research | "What did you find earlier about that topic?" |
| **Web search** | Search engines (Google, Bing, DuckDuckGo) | "Search for Swift 6 release notes" |
| **SerpAPI** | Specialized search (Amazon, eBay, TripAdvisor, Walmart, Yelp) | "Search Amazon for wireless keyboards under $50" |
| **Scrape** | Full page rendering with JavaScript | "Get the content from this web app page" |
| **Fetch** | Fast HTTP fetch (no JavaScript) | "Grab the text from this article URL" |

**Research** is the most powerful option. It:
1. Searches multiple sources
2. Fetches and reads relevant pages
3. Synthesizes findings into a coherent summary
4. Stores results in memory for later recall

---

### Document Operations

**What it does:** Import documents for analysis and create new documents.

#### Import

| Format | What SAM Extracts |
|--------|------------------|
| **PDF** (.pdf) | Full text with layout awareness |
| **Word** (.docx) | Text, headings, structure |
| **Excel** (.xlsx) | Cell data, sheet names |
| **Text** (.txt, .md, .csv) | Full content |

Imported documents are indexed with vector embeddings for semantic search. You can then ask questions about the content naturally.

#### Create

| Format | What SAM Can Generate |
|--------|----------------------|
| **PDF** (.pdf) | Formatted reports and documents |
| **Word** (.docx) | Editable documents |
| **PowerPoint** (.pptx) | Slide presentations |

Just describe what you want: "Create a PDF report summarizing our discussion" or "Make a PowerPoint with 5 slides about the project plan."

---

### Memory Operations

**What it does:** Search and store information across conversations.

| Operation | Description | Example Use |
|-----------|-------------|------------|
| **Search memory** | Semantic search across memories | "What did we discuss about the budget?" |
| **Store memory** | Save information for later | "Remember that the deadline is March 15" |
| **List collections** | See available memory collections | "What memory collections exist?" |
| **Recall history** | Recall topic history | "Recall our recent discussions" |

Memory search uses the same semantic matching as document search - find information by meaning, not just keywords.

---

### Todo Operations

**What it does:** Track multi-step tasks.

| Operation | Description |
|-----------|-------------|
| **Read** | View current task list |
| **Write** | Create or replace the task list |
| **Update** | Mark tasks in-progress, complete, or blocked |
| **Add** | Add new tasks to the list |

The AI uses todos to organize complex work. When you ask SAM to do something with multiple steps, it creates a plan, works through it step by step, and marks items complete as it goes. You can see the progress in the conversation.

---

### Math Operations

**What it does:** Real computation using Python - not AI guessing.

| Operation | Description | Example Use |
|-----------|-------------|------------|
| **Calculate** | Evaluate math expressions | "What's 2^32 - 1?" |
| **Compute** | Run Python code for complex math | "Calculate the standard deviation of [3, 7, 8, 12, 14]" |
| **Convert** | Unit conversions | "Convert 72°F to Celsius" |
| **Formula** | Named financial/practical formulas | "What's the monthly payment on a $400K mortgage at 6.5%?" |

#### Available Formulas

| Formula | What It Calculates |
|---------|-------------------|
| `mortgage` | Monthly payment, total interest, amortization |
| `compound_interest` | Future value with compound interest |
| `tip` | Tip amount and total |
| `bmi` | Body mass index |
| `percentage` | Percentage calculations |
| `markup` | Cost markup and margin |
| `discount` | Discounted price and savings |
| `area_circle` | Area of a circle |
| `area_rectangle` | Area of a rectangle |
| `volume_cylinder` | Volume of a cylinder |
| `speed_distance_time` | Speed, distance, or time calculations |
| `sales_tax` | Price with sales tax |
| `gpa` | GPA / grade calculations |
| `fuel_cost` | Trip fuel cost estimate |
| `cooking` | Recipe scaling |
| `retirement` | Retirement savings projections |
| `debt_payoff` | Single debt payoff timeline |
| `debt_strategy` | Multi-debt payoff plan (snowball or avalanche) |
| `budget` | 50/30/20 budget analysis |
| `loan_comparison` | Compare multiple loan options |
| `savings_goal` | How long to reach a savings target |
| `net_worth` | Assets minus liabilities |
| `paycheck` | Net pay after taxes and deductions |
| `inflation` | Future value adjusted for inflation |

#### Unit Conversions

| Category | Units |
|----------|-------|
| **Temperature** | Fahrenheit, Celsius, Kelvin |
| **Length** | Miles, kilometers, feet, meters, inches, centimeters |
| **Weight** | Pounds, kilograms, ounces, grams |
| **Volume** | Gallons, liters, cups, milliliters |
| **Speed** | mph, km/h, knots |
| **Data** | Bytes, KB, MB, GB, TB |
| **Time** | Seconds, minutes, hours, days |

Every calculation is run through a real Python 3 interpreter. This eliminates the common AI problem of getting math wrong through estimation.

---

### Image Generation

**What it does:** Generate images from text descriptions via a remote ALICE server.

| Operation | Description | Example Use |
|-----------|-------------|------------|
| **Generate** | Create an image from a text prompt | "Create an image of a mountain lake at sunset" |

**Requirements:**
- A running [ALICE](https://github.com/SyntheticAutonomicMind/ALICE) server on your network
- ALICE server configured in SAM Settings

**Features:**
- Automatic model discovery (detects models on your ALICE server)
- Multiple model support (SD 1.5, SDXL, custom models)
- Health monitoring (connection status in Settings)
- Generated images appear directly in the conversation

No local GPU is required. All image generation happens on the ALICE server.

---

### User Collaboration

**What it does:** Pauses the AI to ask you a question.

The AI uses this tool when it needs:
- Clarification on an ambiguous request
- Your choice between multiple valid approaches
- Confirmation before a destructive operation (like deleting files)
- Information that only you know

When the AI uses this tool, you'll see its question in the conversation and can respond normally.

---

## Tool Cards

When SAM executes a tool, you see a tool card in the conversation showing:
- **Tool name** and operation
- **Parameters** being used
- **Status** (running, complete, or failed)
- **Result** (output or error)

Tool cards are collapsible - click to expand or collapse the details.

---

## See Also

- [User Guide](USER_GUIDE.md) - Getting started with SAM
- [Features](FEATURES.md) - Complete feature reference
- [project-docs/MCP_TOOLS_SPECIFICATION.md](../project-docs/MCP_TOOLS_SPECIFICATION.md) - Technical tool specification
- [project-docs/AGENT_ORCHESTRATOR.md](../project-docs/AGENT_ORCHESTRATOR.md) - How the AI orchestrates tool use
