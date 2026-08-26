---
layout: post
title: "Comparing AI Agent Frameworks in the Agentic AI Era"
date: 2026-08-26 19:00:00 +0900
categories: [AI, LLM]
tags: [llm, agent, langchain, langgraph, openai, google-adk, python]
---

## In Coming

Lately every news outlet and every IT company is talking about the arrival of the Agentic AI era.

There is a fair amount of hype in how the press packages Agentic AI, but among developers who actually build with it the assessments differ wildly depending on the use case — it really is a warring-states period.

So what exactly is Agentic AI?

![Agentic AI](/assets/images/2026-08-26/agentic-ai.png)
_Agentic AI_

> AI systems that can independently set goals, make plans, and execute multi-step tasks with minimal human supervision.

In other words, think of it as the collection of AI agent systems that set a goal for the task at hand and then work through several steps to get there.

Agentic AI can be built on workflows with two broad characteristics:

- **Hybrid**: the overall workflow is driven by your own logic, while carrying out each task is delegated to the autonomy of an AI agent
- **Autonomous**: even the decisions about the workflow itself are handed over to the AI agents, which interact with each other and complete the job on their own

This may sound obvious, but the hybrid style is a bit easier to implement and easier to debug, though it hits a ceiling when you try to scale it.

The autonomous style, on the other hand, is hard to implement and extremely hard to debug — but its scalability holds infinite possibilities.

Which shape to build is something you adopt to fit your own situation.

## AI agent framework

To develop and implement a workflow on top of Agentic AI, you need to know what kinds of AI agent frameworks are out there and understand the strengths and weaknesses of each before adopting one.

Today let's walk through which frameworks exist and what their pros and cons are, together with code examples.

## LangChain + LangGraph

First up is the agent framework from the LangChain camp, which dominated the LLM ecosystem early on.

LangChain covers a wide range of AI-related features (RAG, LLM ...) all the way down to low-level building blocks.

LangChain + LangGraph broadly offers the following:

- **State/Memory**: the ability to plug in an in-memory store or a per-session store
- **Middleware**: hooks for each stage of the agent
- **Graph based workflow**: an abstracted workflow built on Node and Edge concepts. A good fit for hybrid workflows

The upside is that you can pick and choose features to suit your own taste, but the flip side is that there are many layers of abstraction, which makes the learning curve steep.

It also integrates with many LLM ecosystems and features, so it carries the downside of being heavy.

Below is an example of a simple weather agent built with LangChain alone.

```python
from dotenv import load_dotenv
from langchain.agents import create_agent
from langchain_core.tools import tool

load_dotenv()


@tool
def get_weather(location: str) -> str:
    """Get current temperature for a given location.

    Args:
        location: City and country e.g. Bogotá, Colombia
    """
    return f"The current temperature in {location} is 15°C with clear skies."


weather_search_agent = create_agent(
    model="openai:gpt-5.4-nano",
    tools=[get_weather],
    system_prompt="You are a weather assistant. For weather-related requests use the tools and respond with a concise summary.",
    name="weather_search_agent",
)


def main() -> None:
    query = "What is the weather in Seoul today?"
    result = weather_search_agent.invoke({"messages": [{"role": "user", "content": query}]})
    print(result["messages"][-1].content)


if __name__ == "__main__":
    main()
```

> [LangChain overview](https://docs.langchain.com/oss/python/langchain/overview)

## OpenAI Agents

Next is OpenAI Agents.

OpenAI Agents is the agent framework OpenAI provides, drawing inspiration from Pydantic AI.

It keeps the concept of a lightweight library, which makes it a good fit for people who want to build an agentic workflow quickly with just a handful of features such as guardrail, handoff, and agent as tool.

- **guardrail**: makes it easy to wire in features that detect security risks
- **handoff / agent as tool**: makes it easy to compose multi-agent patterns as the situation requires
- **tracing**: gives you observability, so you get visibility and easy debugging

You could say it suits you when you want to keep the level of abstraction low and still ship a sophisticated agentic workflow fast.

You can use it with models beyond OpenAI's, but another advantage is how remarkably easy the integration is if you do use OpenAI models.

If you use a model from another vendor, the integration is provided — but you will want to verify that it actually works well.

Below is an example of a simple weather agent built with OpenAI Agents alone.

```python
from agents import Agent, ModelSettings, Runner, function_tool
from dotenv import load_dotenv
from openai.types import Reasoning

load_dotenv()


@function_tool(docstring_style="google")
def get_weather(location: str) -> str:
    """Get current temperature for a given location.

    Args:
        location: City and country e.g. Bogotá, Colombia

    Returns:
        A concise weather sentence that includes Celsius temperature and a condition summary.
    """
    return f"The current temperature in {location} is 15°C with clear skies."


weather_search_agent = Agent(
    name="weather_search_agent",
    instructions="""
    You are a weather assistant. For weather-related requests use the tools and respond with a concise summary.
    """,
    model="gpt-5.4-nano",
    model_settings=ModelSettings(reasoning=Reasoning(effort="none")),
    tools=[get_weather],
)


def main() -> None:
    query = "What is the weather in Seoul today?"
    result = Runner.run_sync(weather_search_agent, input=query)
    print(result.final_output)


if __name__ == "__main__":
    main()
```

If you want a more detailed walkthrough of OpenAI Agents, take a look at the previous post.

> [What an AI Agent Is, and Giving Tools to an Agent (feat. OpenAI)]({% post_url 2026-08-24-ai-agent %})

> [Agents SDK | OpenAI API](https://developers.openai.com/api/docs/guides/agents)

## Google ADK

Google ADK is a built-in solution — it offers platform-level capabilities for developing AI agents.

A variety of agent patterns (Orchestration, Sequential ...) come as a baseline, and built-in observability plus memory/session retention integrate easily with Google Cloud.

- **Agent pattern**: the library provides the agent patterns for your situation so they are easy to use
- **Memory/session**: storage backed by in-memory or a DB
- **Observability**: through `adk web` you can watch the execution steps of your AI agent directly with your own eyes

It ships plenty of features, and if you are on Gemini models and using GCP as well, nothing fits better.

That said, the library is vast, so the learning curve is a downside all the same.

Below is a web search agent example that I built and use myself.

```python
from google.adk.agents.llm_agent import Agent
from google.adk.tools import google_search

from .prompt import AI_THESIS_RESEARCH_INSTRUCTION
from .prompt import GENERAL_WEB_RESEARCH_INSTRUCTION
from .prompt import ROUTER_INSTRUCTION

general_web_search_agent = Agent(
    model="gemini-3-flash-preview",
    name="general_web_search_agent",
    description=(
        "General-purpose web researcher for non-thesis topics. Uses web search "
        "and returns a cited report."
    ),
    instruction=GENERAL_WEB_RESEARCH_INSTRUCTION,
    tools=[google_search],
    disallow_transfer_to_parent=True,
    disallow_transfer_to_peers=True,
)

ai_thesis_search_agent = Agent(
    model="gemini-3-flash-preview",
    name="ai_thesis_search_agent",
    description=(
        "AI paper and thesis-style research specialist for literature reviews, "
        "paper comparisons, and methodology analysis."
    ),
    instruction=AI_THESIS_RESEARCH_INSTRUCTION,
    tools=[google_search],
    disallow_transfer_to_parent=True,
    disallow_transfer_to_peers=True,
)

web_search_agent = Agent(
    model="gemini-3-flash-preview",
    name="web_search_agent",
    description=(
        "Routes research requests to either the general web search specialist "
        "or the AI thesis research specialist based on topic."
    ),
    instruction=ROUTER_INSTRUCTION,
    sub_agents=[general_web_search_agent, ai_thesis_search_agent],
)

# ADK loaders and deploy flows expect `root_agent` by default.
root_agent = web_search_agent
```

> [Agent Development Kit (ADK)](https://adk.dev/)

## MAF (Microsoft Agent Framework)

This is the agent framework the Microsoft camp has started offering, newly unifying the familiar [Autogen](https://github.com/microsoft/autogen) and [Semantic Kernel](https://github.com/microsoft/semantic-kernel) libraries.

The focus is on merging the various agent patterns from Autogen with the enterprise-grade session storage from Semantic Kernel into a single thing.

- **Agent pattern**: a range of agent patterns (orchestration, handoff ...)
- **Memory/session**: state management through agent sessions and context providers

Below is an example of a `weather_agent` implemented with Microsoft Agent Framework.

```python
import asyncio

from agent_framework import Agent, tool
from agent_framework.openai import OpenAIChatClient
from dotenv import load_dotenv

load_dotenv()


@tool
def get_weather(location: str) -> str:
    """Get current temperature for a given location.

    Args:
        location: City and country e.g. Bogotá, Colombia
    """
    return f"The current temperature in {location} is 15°C with clear skies."


client = OpenAIChatClient(model="gpt-5.4-nano")

weather_search_agent = Agent(
    client=client,
    name="weather_search_agent",
    instructions="You are a weather assistant. For weather-related requests use the tools and respond with a concise summary.",
    tools=[get_weather],
)


async def main() -> None:
    query = "What is the weather in Seoul today?"
    result = await weather_search_agent.run(query)
    print(result.text)


if __name__ == "__main__":
    asyncio.run(main())
```

> [Agent Framework documentation](https://learn.microsoft.com/en-us/agent-framework/)

## Conclusion

Today we went through a variety of AI agent frameworks.

Each has its own strengths and weaknesses, and each has a clear purpose — so it would be good to pick the framework that fits your situation.

- If you like the smallest learning curve and a lightweight style → **OpenAI Agents**
- If you want to build out a fixed workflow in depth → **LangChain + LangGraph**
- If you want easy integration with the Google ecosystem and platform-level features → **Google ADK**
- If you want easy integration with the Microsoft ecosystem and enterprise-grade agent workflows → **MAF**

There are other agent frameworks out there too, so it is worth looking around and trying them out :)

## Reference

> [LangChain overview](https://docs.langchain.com/oss/python/langchain/overview)

> [Agents SDK | OpenAI API](https://developers.openai.com/api/docs/guides/agents)

> [Agent Development Kit (ADK)](https://adk.dev/)

> [Agent Framework documentation](https://learn.microsoft.com/en-us/agent-framework/)
