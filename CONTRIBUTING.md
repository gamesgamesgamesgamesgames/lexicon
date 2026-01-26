# Contributing

Thank you for your interest in contributing to the `games.gamesgamesgamesgames.*` lexicon namespace! This guide will help you understand how to propose new lexicons and submit changes.

## Code of Conduct

All contributions to this project — code, documentation, discussions, and community interactions — are subject to our [Code of Conduct](CODE_OF_CONDUCT.md). Please read it before participating.

## Understanding Lexicons

Before contributing, familiarize yourself with ATProto's Lexicon system:

- [ATProto Lexicon Guide](https://atproto.com/guides/lexicon) — The official documentation
- Review existing lexicons in the `src/` directory of this repository

Lexicons define the schema for records stored in ATProto repositories. This namespace focuses specifically on video game-related data, enabling applications to:

- Store and retrieve game metadata
- Track player achievements and progress
- Build trophy cases and game directories
- Create interoperable gaming experiences on ATProto

This is not an exhaustive list, but it does encompass the spirit of the project. Lexicons may not adhere to these purposes.

## Proposing Changes (RFCs)

All significant changes to this namespace require an RFC (Request for Comments). This includes:

- New record types (e.g., achievements, playtime tracking)
- New token definitions (e.g., new genres, platforms)
- New queries or procedures
- Modifications to existing lexicons

### Creating an RFC

1. **Open an issue** using the [Lexicon RFC template](https://github.com/gamesgamesgamesgamesgames/lexicon/issues/new?template=rfc.yml)
2. **Fill out all required sections**, including:
   - The proposed NSID (must use `games.gamesgamesgamesgames.*`)
   - A clear summary of the lexicon's purpose
   - Video game-specific use cases
   - A draft schema in JSON format
3. **Engage in discussion** — respond to feedback and iterate on your proposal

### What Makes a Good RFC

**Clear purpose**: Explain what video game-related problem this lexicon solves. Generic data structures that aren't specific to gaming belong elsewhere, like [`community.lexicon.*`](https://github.com/lexicon-community/lexicon).

**Concrete use cases**: Describe specific scenarios where this lexicon would be used. "Players can track speedrun times" is better than "enables time tracking."

**Well-designed schema**: Your proposed schema should:

- Follow Lexicon conventions (see existing schemas for reference)
- Include descriptions for all fields
- Use appropriate types and constraints
- Reference existing definitions where applicable (e.g., `games.gamesgamesgamesgames.defs#genre`)

**Extensibility planning**: Consider how your lexicon might need to evolve:

- Prefer `knownValues` over `enum` for fields that may have emerging taxonomies
- Design for backwards compatibility from the start

## Pull Requests

Once an RFC has been discussed and approved, you can submit a pull request with the implementation.

### Guidelines

**Minimal changes**: Each PR should focus on a single lexicon or a cohesive set of related changes. Avoid bundling unrelated modifications.

**Backwards compatibility**: Published lexicons cannot have breaking changes. This means:

- Never remove or rename existing fields
- Never tighten constraints (e.g., adding new `required` fields)
- Never change the meaning of existing values
- To make significant changes, create a new lexicon with a new NSID

**Follow existing patterns**: Look at existing lexicons in the repository and match their style:

- Use consistent naming conventions (camelCase for field names)
- Include descriptions for records and fields
- Place shared definitions in `defs.json` when appropriate
- Define tokens in their own files (e.g., `genre.json`, `mode.json`)

**Validate your schema**: Ensure your JSON is valid and follows the Lexicon specification.

### PR Checklist

Before submitting:

- [ ] Your changes are linked to an approved RFC issue
- [ ] Schema JSON is valid and well-formatted
- [ ] All fields have descriptions
- [ ] Changes are backwards compatible (or this is a new lexicon)
- [ ] You have tested that references to other definitions are correct

## Questions?

If you're unsure whether your idea fits this namespace or need guidance on your proposal, feel free to open a discussion issue before creating a formal RFC.
