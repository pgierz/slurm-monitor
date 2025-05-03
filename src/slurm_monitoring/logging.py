from loguru import logger

# Configure logger to use square brackets around the level
logger.remove()
logger.add(
    lambda msg: print(msg, end=""),
    format="{time:YYYY-MM-DD HH:mm:ss.SSS} | [{level}] | {name}:{function}:{line} - {message}",
    level="DEBUG",
)
