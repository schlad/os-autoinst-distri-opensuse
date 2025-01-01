const fs = require('fs');
const path = require('path');

// Function to extract structured key-value pairs from a single file
const extractStructuredData = (filePath) => {
  const result = {};
  let currentKey = '';
  let multiLineValue = '';

  const fileContent = fs.readFileSync(filePath, 'utf8');
  const lines = fileContent.split('\n');

  for (const line of lines) {
    const trimmedLine = line.trim();

    if (trimmedLine.startsWith('use')) {
      break;
    }

    if (trimmedLine.startsWith('#')) {
      const content = trimmedLine.substring(1).trim();

      if (content.startsWith("SUSE's OpenQA tests")) {
        result.header = content;
      } else if (content.startsWith('Copyright')) {
        result.copyrights = content;
      } else if (content.startsWith('License') || content.startsWith('SPDX-License-Identifier')) {
        result.license = content;
      } else if (content.startsWith('Test Specification')) {
        result.testSpecification = content.replace('Test Specification:', '').trim();
      } else if (content.startsWith('Test Name')) {
        result.testName = content.replace('Test Name:', '').trim();
      } else if (content.startsWith('Summary')) {
        currentKey = 'testDescription';
        multiLineValue = content.replace('Test Description:', '').trim();
      } else if (content.startsWith('Maintainer')) {
        result.maintainers = content.replace('Maintainers:', '').trim();
      } else if (content.startsWith('Tags')) {
        result.tags = content.replace('Tags:', '').split(',').map(tag => tag.trim());
      } else if (currentKey === 'testDescription') {
        multiLineValue += ' ' + content;
      }
    }
  }

  if (multiLineValue) {
    result[currentKey] = multiLineValue.trim();
  }

  return result;
};

// Function to recursively get all files in a directory
const getAllFiles = (dirPath, filesArray = []) => {
  const files = fs.readdirSync(dirPath);

  files.forEach(file => {
    const filePath = path.join(dirPath, file);
    if (fs.statSync(filePath).isDirectory()) {
      // Recursively search in subdirectories
      getAllFiles(filePath, filesArray);
    } else {
      filesArray.push(filePath);
    }
  });

  return filesArray;
};

const processDirectory = (directoryPath) => {
  const allFiles = getAllFiles(directoryPath);
  const results = [];

  allFiles.forEach(filePath => {
    if (filePath.endsWith('.pm')) {
      const parsedData = extractStructuredData(filePath);
      results.push(parsedData);
    }
  });

  fs.writeFileSync('output.json', JSON.stringify(results, null, 2));
  console.log("All extracted data written to output.json");
};

const directoryPath = './tests';
processDirectory(directoryPath);